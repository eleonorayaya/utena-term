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
    func session(_ session: TmuxControlSession, didRenameWindow windowID: String, to newName: String)
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

    func start(tmuxPath: String, attachingTo target: String? = nil) throws {

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
        // Forward LC_* in addition to LANG so the inner shell + tmux see a
        // UTF-8 locale. Falling back to LANG/LC_CTYPE = en_US.UTF-8 when the
        // host hasn't set them ensures multibyte chars don't get mangled into
        // single-byte cells (the â/Â everywhere bug).
        let envKeys = [
            "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "XDG_CONFIG_HOME",
            "LANG", "LC_ALL", "LC_CTYPE", "LC_COLLATE", "LC_MESSAGES",
        ]
        var envEntries: [String] = ["TERM=screen-256color"]
        var hadLang = false, hadLcCtype = false
        for key in envKeys {
            if let val = env[key] {
                envEntries.append("\(key)=\(val)")
                if key == "LANG" { hadLang = true }
                if key == "LC_CTYPE" || key == "LC_ALL" { hadLcCtype = true }
            }
        }
        if !hadLang { envEntries.append("LANG=en_US.UTF-8") }
        if !hadLcCtype { envEntries.append("LC_CTYPE=en_US.UTF-8") }

        // -u forces tmux's UTF-8 mode regardless of locale detection.
        var argv: ContiguousArray<UnsafeMutablePointer<CChar>?>
        if let target {
            argv = [strdup(tmuxPath), strdup("-u"), strdup("-CC"), strdup("attach-session"), strdup("-t"), strdup(target), nil]
        } else {
            argv = [strdup(tmuxPath), strdup("-u"), strdup("-CC"), strdup("new-session"), nil]
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

    // Fire-and-forget: sends bytes to a pane.
    //
    // Bytes split into runs:
    //   - Control bytes (< 0x20 or == 0x7F): sent via `send-keys -H <hex>` so
    //     tmux delivers them as raw bytes to the pane pty (e.g. ⌃c → 0x03,
    //     ⌃o → 0x0F, ESC → 0x1B). This is the only reliable path: octal
    //     escapes inside double-quoted args (e.g. "\017") are silently dropped
    //     by tmux's control-mode command parser, and `-l` doesn't honor them
    //     either — both paths leave control chords undelivered.
    //   - Printable + UTF-8 high bytes: quoted, sent WITH -l as literal text.
    func sendKeys(pane paneID: String, data: Data) {
        let bytes = Array(data)
        var i = 0
        while i < bytes.count {
            if Self.isControlByte(bytes[i]) {
                var hexArgs = ""
                while i < bytes.count, Self.isControlByte(bytes[i]) {
                    hexArgs += String(format: " %02x", bytes[i])
                    i += 1
                }
                rawWrite("send-keys -t \(paneID) -H\(hexArgs)\n")
            } else {
                var run: [UInt8] = []
                while i < bytes.count, !Self.isControlByte(bytes[i]) {
                    run.append(bytes[i])
                    i += 1
                }
                rawWrite("send-keys -t \(paneID) -l \(Self.tmuxQuoteBytes(run))\n")
            }
        }
    }

    private static func isControlByte(_ b: UInt8) -> Bool { b < 0x20 || b == 0x7F }

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

    func toggleZoom(target paneID: String) {
        rawWrite("resize-pane -Z -t \(paneID)\n")
    }

    func renameWindow(target windowID: String, name: String) {
        // Escape backslashes and quotes to handle spaces and special characters
        let escaped = name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        rawWrite("rename-window -t \(windowID) \"\(escaped)\"\n")
    }

    func listSessions() async throws -> String {
        try await send("list-sessions -F '#{session_id} #{session_name}'")
    }

    func listWindows() async throws -> String {
        try await send("list-windows -F '#{window_id} #{window_layout}'")
    }

    func listWindowsWithNames() async throws -> String {
        try await send("list-windows -F '#{window_id} #{window_name}'")
    }

    func refreshClient(cols: Int, rows: Int) {
        rawWrite("refresh-client -C \(cols)x\(rows)\n")
    }

    // MARK: - Private

    private func rawWrite(_ s: String) {
        let fd = masterFd
        // TEMP DEBUG: dump every command we send to tmux so we can verify the
        // send-keys path is actually emitting `-H 0f` for ⌃o etc.
        if ProcessInfo.processInfo.environment["UTENA_TMUX_LOG"] != nil {
            FileHandle.standardError.write(Data("[tmux→] \(s)".utf8))
        }
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
                let lineCopy = Data(trimmed)
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlIdx)
                handleLine(lineCopy)
            }
        }
        failAllPending()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sessionDidClose(self)
        }
    }

    private static let outputPrefix: [UInt8] = Array("%output ".utf8)

    private func handleLine(_ rawLine: Data) {
        // tmux prepends a DCS intro (\033P<params><final-byte>) to the first control-mode
        // line. Strip it before parsing at the byte level so binary %output payloads
        // (UTF-8 multibyte, escape sequences) survive untouched.
        var bytes = rawLine
        if bytes.count >= 2,
           bytes[bytes.startIndex] == 0x1B,
           bytes[bytes.startIndex + 1] == 0x50 {
            var i = bytes.startIndex + 2
            while i < bytes.endIndex, !(bytes[i] >= 0x40 && bytes[i] <= 0x7E) {
                i += 1
            }
            if i < bytes.endIndex {
                bytes = bytes[(i + 1)...]
            }
        }
        if bytes.isEmpty { return }

        // Fast path for %output: bypass the String round-trip. Decoding raw pane
        // bytes as a Swift String with an ISO-Latin1 fallback (the obvious naïve
        // path) silently expands every UTF-8 high byte the moment ANY byte in the
        // line fails UTF-8 validation, producing the â/Â garbled-char bug. Stay in
        // bytes until we hand off to the VT parser.
        if bytes.count >= Self.outputPrefix.count,
           bytes.prefix(Self.outputPrefix.count).elementsEqual(Self.outputPrefix) {
            let after = bytes.index(bytes.startIndex, offsetBy: Self.outputPrefix.count)
            guard let spaceIdx = bytes[after...].firstIndex(of: 0x20),
                  let paneID = String(bytes: bytes[after..<spaceIdx], encoding: .ascii)
            else { return }
            let payload = bytes[(spaceIdx + 1)...]
            let data = ControlLineParser.unescapeOctal(Data(payload))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didReceiveOutput: data, forPane: paneID)
            }
            return
        }

        // Other events carry only ASCII / simple UTF-8 names — round-trip is safe.
        let line = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
        if line.isEmpty { return }
        let event = parser.parse(line)
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

        case .windowRenamed(let windowID, let newName):
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didRenameWindow: windowID, to: newName)
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

    // Quotes a run of non-control bytes as a double-quoted tmux string.
    // Caller has already filtered out bytes < 0x20 / 0x7F. UTF-8 high bytes
    // (0x80-0xFF) pass through unmodified — tmux accepts them inside quotes
    // when -l is in effect. Only \ and " need escaping.
    private static func tmuxQuoteBytes(_ bytes: [UInt8]) -> String {
        var result = "\""
        for byte in bytes {
            switch byte {
            case UInt8(ascii: "\\"):
                result += "\\\\"
            case UInt8(ascii: "\""):
                result += "\\\""
            default:
                result.append(Character(UnicodeScalar(byte)))
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
