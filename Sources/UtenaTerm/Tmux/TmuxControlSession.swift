import Foundation
import Darwin

private let TIOCSWINSZ_REQ: UInt = 0x80087467
private let TIOCSCTTY_REQ: UInt = 0x20007461
@_silgen_name("fork") private func _fork() -> pid_t

enum TmuxError: Error {
    case tmuxNotFound
    case spawnFailed
}

enum TmuxCommandError: Error {
    case commandFailed(String)
    case sessionClosed
}

protocol TmuxControlSessionDelegate: AnyObject {
    func session(_ session: TmuxControlSession, didReceiveOutput data: Data, forPane paneID: String)
    func session(_ session: TmuxControlSession, didLayoutChange layout: String, forWindow windowID: String)
    func session(_ session: TmuxControlSession, didAddWindow windowID: String)
    func session(_ session: TmuxControlSession, didCloseWindow windowID: String)
    func session(_ session: TmuxControlSession, didChangeTo sessionID: String, name: String)
    func session(_ session: TmuxControlSession, didSelectWindow windowID: String)
    func session(_ session: TmuxControlSession, paneDidExit paneID: String)
    func sessionDidClose(_ session: TmuxControlSession)
}

final class TmuxControlSession {
    weak var delegate: TmuxControlSessionDelegate?

    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0
    private let parser = ControlLineParser()

    // Protects pendingContinuations. Also serializes append+write scheduling in send().
    private let continuationsLock = NSLock()
    private var pendingContinuations: [CheckedContinuation<String, Error>] = []

    // Only accessed from the read thread — no lock needed.
    private var outputAccumulator = ""
    private var inBlock = false

    private let writeQueue = DispatchQueue(label: "com.utena-term.tmux.write", qos: .userInteractive)

    func start(tmuxPath: String, groupingWith target: String? = nil) throws {

        let master = posix_openpt(O_RDWR | O_NOCTTY)
        precondition(master >= 0, "posix_openpt failed")
        _ = grantpt(master)
        _ = unlockpt(master)

        let slaveName = String(cString: ptsname(master))
        let slave = open(slaveName, O_RDWR)
        precondition(slave >= 0, "open slave pty failed")

        var ws = winsize(ws_row: 50, ws_col: 220, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_REQ, &ws)

        let env = ProcessInfo.processInfo.environment
        let envKeys = ["HOME", "PATH", "USER", "LOGNAME", "LANG", "TMPDIR", "XDG_CONFIG_HOME"]
        var envEntries: [String] = ["TERM=screen-256color"]
        for key in envKeys {
            if let val = env[key] { envEntries.append("\(key)=\(val)") }
        }

        var argv: ContiguousArray<UnsafeMutablePointer<CChar>?>
        if let target {
            argv = [strdup(tmuxPath), strdup("-CC"), strdup("new-session"), strdup("-t"), strdup(target), nil]
        } else {
            argv = [strdup(tmuxPath), strdup("-CC"), strdup("new-session"), nil]
        }
        var envp: ContiguousArray<UnsafeMutablePointer<CChar>?> =
            ContiguousArray(envEntries.map { strdup($0) } + [nil])

        var pid: pid_t = 0
        argv.withUnsafeMutableBufferPointer { argvBuf in
            envp.withUnsafeMutableBufferPointer { envpBuf in
                pid = _fork()
                if pid == 0 {
                    _ = setsid()
                    _ = ioctl(slave, TIOCSCTTY_REQ, 0)
                    _ = dup2(slave, STDIN_FILENO)
                    _ = dup2(slave, STDOUT_FILENO)
                    _ = dup2(slave, STDERR_FILENO)
                    close(slave)
                    close(master)
                    _ = execve(argvBuf[0]!, argvBuf.baseAddress, envpBuf.baseAddress)
                    _exit(1)
                }
            }
        }
        guard pid > 0 else {
            close(slave); close(master); throw TmuxError.spawnFailed
        }

        for ptr in argv where ptr != nil { free(ptr) }
        for ptr in envp where ptr != nil { free(ptr) }

        close(slave)
        masterFd = master
        childPid = pid

        let t = Thread { [weak self] in
            Thread.current.name = "tmux-read"
            self?.readLoop()
        }
        t.start()
    }

    // Sends a command and waits for the matching %begin/%end response block.
    func send(_ command: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let fd = masterFd
            continuationsLock.lock()
            pendingContinuations.append(continuation)
            continuationsLock.unlock()
            writeQueue.async {
                guard fd >= 0 else { return }
                var bytes = Array((command + "\n").utf8)
                _ = Darwin.write(fd, &bytes, bytes.count)
            }
        }
    }

    // Fire-and-forget: sends literal bytes to a pane.
    func sendKeys(pane paneID: String, data: Data) {
        let quoted = Self.tmuxQuoteData(data)
        rawWrite("send-keys -t \(paneID) -l \(quoted)\n")
    }

    func splitPane(target paneID: String, vertical: Bool) async throws {
        let flag = vertical ? "-v" : "-h"
        _ = try await send("split-window \(flag) -t \(paneID)")
    }

    func killPane(target paneID: String) {
        rawWrite("kill-pane -t \(paneID)\n")
    }

    func selectPane(target paneID: String) {
        rawWrite("select-pane -t \(paneID)\n")
    }

    func switchSession(name: String) {
        rawWrite("switch-client -t \(name)\n")
    }

    func newWindow() {
        rawWrite("new-window\n")
    }

    func killWindow(target windowID: String) {
        rawWrite("kill-window -t \(windowID)\n")
    }

    func listSessions() async throws -> String {
        try await send("list-sessions -F '#{session_id} #{session_name}'")
    }

    func listWindows() async throws -> String {
        try await send("list-windows -F '#{window_id} #{window_layout}'")
    }

    func refreshClient(cols: Int, rows: Int) {
        rawWrite("refresh-client -C \(cols)x\(rows)\n")
    }

    // MARK: - Private

    private func rawWrite(_ s: String) {
        let fd = masterFd
        writeQueue.async {
            guard fd >= 0 else { return }
            var bytes = Array(s.utf8)
            _ = Darwin.write(fd, &bytes, bytes.count)
        }
    }

    private func readLoop() {
        var lineBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(masterFd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue } else { break } }
            if n == 0 { break }
            lineBuffer.append(contentsOf: buf[..<n])
            while let nlIdx = lineBuffer.firstIndex(of: 0x0A) {
                let lineBytes = lineBuffer[lineBuffer.startIndex..<nlIdx]
                let trimmed = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlIdx)
                let lineStr = String(bytes: trimmed, encoding: .utf8)
                    ?? String(bytes: trimmed, encoding: .isoLatin1)
                    ?? ""
                handleLine(lineStr)
            }
        }
        failAllPending()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sessionDidClose(self)
        }
    }

    private func handleLine(_ rawLine: String) {
        // tmux prepends a DCS intro (\033P<params><final-byte>) to the first control-mode
        // line.  Strip it before parsing so "%begin" etc. are found correctly.
        let line: String
        if rawLine.hasPrefix("\u{1B}P") {
            // Find the DCS final byte (first char in 0x40–0x7E after the ESC P).
            let afterP = rawLine.index(rawLine.startIndex, offsetBy: 2)
            if let finalIdx = rawLine[afterP...].firstIndex(where: { $0.asciiValue.map { $0 >= 0x40 && $0 <= 0x7E } ?? false }) {
                line = String(rawLine[rawLine.index(after: finalIdx)...])
            } else {
                line = rawLine
            }
        } else {
            line = rawLine
        }
        if line.isEmpty { return }
        let event = parser.parse(line)
        if line.hasPrefix("%") { DebugLog.log("tmux-raw", line) }
        switch event {
        case .beginBlock:
            outputAccumulator = ""
            inBlock = true

        case .endBlock:
            let output = outputAccumulator
            outputAccumulator = ""
            inBlock = false
            let cont = dequeueContinuation()
            cont?.resume(returning: output)

        case .errorBlock:
            let output = outputAccumulator
            outputAccumulator = ""
            inBlock = false
            let cont = dequeueContinuation()
            cont?.resume(throwing: TmuxCommandError.commandFailed(output))

        case .output(let paneID, let data):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didReceiveOutput: data, forPane: paneID)
            }

        case .layoutChange(let windowID, let layout):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didLayoutChange: layout, forWindow: windowID)
            }

        case .windowAdd(let windowID):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didAddWindow: windowID)
            }

        case .windowClose(let windowID):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didCloseWindow: windowID)
            }

        case .sessionChanged(let sessionID, let name):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didChangeTo: sessionID, name: name)
            }

        case .sessionWindowChanged(_, let windowID):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didSelectWindow: windowID)
            }

        case .paneExited(let paneID):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, paneDidExit: paneID)
            }

        case .pasteBufferChanged, .unknown:
            // Accumulate plain lines that arrive between %begin and %end as command output.
            if inBlock { outputAccumulator += line + "\n" }
        }
    }

    private func dequeueContinuation() -> CheckedContinuation<String, Error>? {
        continuationsLock.lock()
        defer { continuationsLock.unlock() }
        guard !pendingContinuations.isEmpty else { return nil }
        return pendingContinuations.removeFirst()
    }

    private func failAllPending() {
        continuationsLock.lock()
        let all = pendingContinuations
        pendingContinuations = []
        continuationsLock.unlock()
        for c in all { c.resume(throwing: TmuxCommandError.sessionClosed) }
    }

    static func listExistingSessions(tmuxPath: String) -> [(id: String, name: String)] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["list-sessions", "-F", "#{session_id} #{session_name}"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return [] }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (id: String(parts[0]), name: String(parts[1]))
        }
    }

    static func findTmux() -> String? {
        let pathVar = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
        for dir in pathVar.split(separator: ":").map(String.init) {
            let candidate = dir + "/tmux"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // Quotes binary data as a double-quoted tmux control-mode string.
    // Octal-escapes control bytes and high bytes; escapes \ and ".
    private static func tmuxQuoteData(_ data: Data) -> String {
        var result = "\""
        for byte in data {
            switch byte {
            case UInt8(ascii: "\\"):
                result += "\\\\"
            case UInt8(ascii: "\""):
                result += "\\\""
            case 0x20 ... 0x7E:
                result.append(Character(UnicodeScalar(byte)))
            default:
                result += String(format: "\\%03o", byte)
            }
        }
        result += "\""
        return result
    }

    deinit {
        if childPid > 0 { kill(childPid, SIGTERM) }
        if masterFd >= 0 { close(masterFd) }
    }
}
