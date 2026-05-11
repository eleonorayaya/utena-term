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
        // Forward LC_* / LANG so tmux + the inner shell see a UTF-8 locale;
        // fall back to en_US.UTF-8 when the host hasn't set them.
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

    // Fire-and-forget: sends bytes to a pane, split into runs by content type.
    // Control bytes (< 0x20 or == 0x7F) go through `-H <hex>` — the only
    // reliable path; both quoted octal escapes and `-l` drop them silently in
    // control mode. Printable + UTF-8 high bytes go through `-l` as literal
    // text so multibyte sequences stay intact.
    func sendKeys(pane paneID: String, data: Data) {
        var i = data.startIndex
        while i < data.endIndex {
            if Self.isControlByte(data[i]) {
                var hexArgs = ""
                while i < data.endIndex, Self.isControlByte(data[i]) {
                    hexArgs += " "
                    hexArgs += Self.hex2[Int(data[i])]
                    i += 1
                }
                rawWrite("send-keys -t \(paneID) -H\(hexArgs)\n")
            } else {
                let runStart = i
                while i < data.endIndex, !Self.isControlByte(data[i]) {
                    i += 1
                }
                let quoted = Self.tmuxQuoteBytes(data[runStart..<i])
                rawWrite("send-keys -t \(paneID) -l \(quoted)\n")
            }
        }
    }

    private static func isControlByte(_ b: UInt8) -> Bool { b < 0x20 || b == 0x7F }

    /// Precomputed two-digit lowercase hex strings for every byte value.
    /// `String(format:)` allocates per call; this fires per-byte per keystroke.
    private static let hex2: [String] = (0...0xFF).map { String(format: "%02x", $0) }

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
        rawWrite("rename-window -t \(windowID) \(Self.tmuxQuoteBytes(name.utf8))\n")
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
        writeQueue.async {
            guard fd >= 0 else { return }
            var bytes = Array(s.utf8)
            _ = Darwin.write(fd, &bytes, bytes.count)
            Signpost.event("tmuxWrite", "bytes=\(bytes.count)")
        }
    }

    private func readLoop() {
        var lineBuffer = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Per-syscall coalescing: each Darwin.read may yield N complete lines.
        // Instead of N main-queue hops we collect delegate calls into a single
        // batch and dispatch once per drained syscall. Consecutive %output for
        // the same pane is merged into one Data so the receiving pane does a
        // single bridge.write FFI call instead of N. Wire order across panes
        // and across event types is preserved.
        var batch = DelegateCallBatcher()
        while true {
            let n = Darwin.read(masterFd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue } else { break } }
            if n == 0 { break }
            lineBuffer.append(contentsOf: buf[..<n])
            while let nlIdx = lineBuffer.firstIndex(of: 0x0A) {
                let lineBytes = lineBuffer[lineBuffer.startIndex..<nlIdx]
                let trimmed = lineBytes.last == 0x0D ? lineBytes.dropLast() : lineBytes
                if let call = handleLine(trimmed) {
                    batch.append(call)
                }
                lineBuffer.removeSubrange(lineBuffer.startIndex...nlIdx)
            }
            let calls = batch.drain()
            if !calls.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let delegate = self.delegate else { return }
                    for call in calls {
                        Self.deliver(call, on: delegate, session: self)
                    }
                }
            }
        }
        failAllPending()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sessionDidClose(self)
        }
    }

    // MARK: - Coalescing helpers (visible to tests)

    enum PendingDelegateCall: Equatable {
        case output(paneID: String, data: Data)
        case layoutChange(windowID: String, layout: String)
        case windowAdd(windowID: String)
        case windowClose(windowID: String)
        case windowRenamed(windowID: String, newName: String)
        case sessionChanged(sessionID: String, name: String)
        case selectWindow(windowID: String)
        case paneExited(paneID: String)
    }

    /// Per-syscall accumulator for delegate calls produced by handleLine.
    ///
    /// Consecutive `.output` for the same pane is merged into a single Data
    /// buffer so the receiving pane does one `bridge.write` instead of N.
    /// Any non-output event flushes the accumulator first, preserving wire
    /// order between bytes and structural events (layout changes etc.).
    ///
    /// The pane id and the merge buffer live in separate fields rather than
    /// in a single `(String, Data)?` tuple so that appending to `pendingData`
    /// doesn't trip Swift's COW: in the tuple form the optional and the
    /// local `var cur` both held strong refs to the buffer, forcing a full
    /// copy on every merge (O(N²) total bytes copied across N consecutive
    /// same-pane lines, which is exactly the paste/scroll path the
    /// coalescer is meant to optimize).
    struct DelegateCallBatcher {
        private(set) var pending: [PendingDelegateCall] = []
        private var pendingPaneID: String?
        private var pendingData = Data()

        mutating func append(_ call: PendingDelegateCall) {
            if case .output(let paneID, let data) = call {
                if pendingPaneID == paneID {
                    pendingData.append(data)
                } else {
                    flush()
                    pendingPaneID = paneID
                    pendingData = data
                }
            } else {
                flush()
                pending.append(call)
            }
        }

        mutating func flush() {
            guard let id = pendingPaneID else { return }
            pending.append(.output(paneID: id, data: pendingData))
            pendingPaneID = nil
            pendingData = Data()
        }

        /// Flush any accumulated output and return the full ordered batch,
        /// resetting the batcher's storage for the next syscall.
        mutating func drain() -> [PendingDelegateCall] {
            flush()
            defer { pending.removeAll(keepingCapacity: true) }
            return pending
        }
    }

    private static func deliver(
        _ call: PendingDelegateCall,
        on delegate: TmuxControlSessionDelegate,
        session: TmuxControlSession
    ) {
        switch call {
        case .output(let paneID, let data):
            delegate.session(session, didReceiveOutput: data, forPane: paneID)
        case .layoutChange(let windowID, let layout):
            delegate.session(session, didLayoutChange: layout, forWindow: windowID)
        case .windowAdd(let id):
            delegate.session(session, didAddWindow: id)
        case .windowClose(let id):
            delegate.session(session, didCloseWindow: id)
        case .windowRenamed(let id, let newName):
            delegate.session(session, didRenameWindow: id, to: newName)
        case .sessionChanged(let id, let name):
            delegate.session(session, didChangeTo: id, name: name)
        case .selectWindow(let id):
            delegate.session(session, didSelectWindow: id)
        case .paneExited(let id):
            delegate.session(session, paneDidExit: id)
        }
    }

    private static let outputPrefix: [UInt8] = Array("%output ".utf8)

    private enum B {
        static let esc: UInt8 = 0x1B           // ESC, DCS intro lead
        static let dcsP: UInt8 = 0x50          // 'P', DCS intro second byte
        static let space: UInt8 = 0x20
        static let dcsFinal: ClosedRange<UInt8> = 0x40 ... 0x7E
    }

    /// Parse one wire-line into either a deferred delegate call (returned) or
    /// an inline state mutation (continuation completion / accumulator append).
    /// Returning a value lets the read loop coalesce per-syscall main-queue
    /// dispatches; continuations still resume immediately on the read thread
    /// so awaiters aren't held up behind the next syscall.
    private func handleLine(_ rawLine: Data) -> PendingDelegateCall? {
        // Strip tmux's DCS intro (`ESC P <params> <final 0x40-0x7E>`) at the
        // byte level so binary %output payloads further down survive intact.
        // NB: `bytes` is a Data slice — its indices are absolute (non-zero
        // startIndex), so all index arithmetic below uses bytes.startIndex /
        // endIndex, never `0` / `count`.
        var bytes = rawLine
        if bytes.count >= 2,
           bytes[bytes.startIndex] == B.esc,
           bytes[bytes.startIndex + 1] == B.dcsP {
            var i = bytes.startIndex + 2
            while i < bytes.endIndex, !B.dcsFinal.contains(bytes[i]) {
                i += 1
            }
            if i < bytes.endIndex {
                bytes = bytes[(i + 1)...]
            }
        }
        if bytes.isEmpty { return nil }

        // %output payloads MUST stay in bytes — decoding through Swift String
        // with a Latin-1 fallback expands every UTF-8 high byte whenever any
        // byte in the line fails UTF-8 validation (the â/Â corruption).
        if bytes.count >= Self.outputPrefix.count,
           bytes.prefix(Self.outputPrefix.count).elementsEqual(Self.outputPrefix) {
            let after = bytes.index(bytes.startIndex, offsetBy: Self.outputPrefix.count)
            guard let spaceIdx = bytes[after...].firstIndex(of: B.space),
                  let paneID = String(bytes: bytes[after..<spaceIdx], encoding: .ascii)
            else { return nil }
            let data = ControlLineParser.unescapeOctal(bytes[(spaceIdx + 1)...])
            Signpost.event("tmuxOutput", "pane=\(paneID) bytes=\(data.count)")
            return .output(paneID: paneID, data: data)
        }

        // All other events are ASCII / simple UTF-8 names — String is fine.
        let line = String(bytes: bytes, encoding: .utf8)
            ?? String(bytes: bytes, encoding: .isoLatin1)
            ?? ""
        if line.isEmpty { return nil }
        let event = parser.parse(line)
        switch event {
        case .beginBlock:
            outputAccumulator = ""
            inBlock = true
            return nil

        case .endBlock:
            let output = outputAccumulator
            outputAccumulator = ""
            inBlock = false
            let cont = dequeueContinuation()
            cont?.resume(returning: output)
            return nil

        case .errorBlock:
            let output = outputAccumulator
            outputAccumulator = ""
            inBlock = false
            let cont = dequeueContinuation()
            cont?.resume(throwing: TmuxCommandError.commandFailed(output))
            return nil

        case .layoutChange(let windowID, let layout):
            return .layoutChange(windowID: windowID, layout: layout)

        case .windowAdd(let windowID):
            return .windowAdd(windowID: windowID)

        case .windowClose(let windowID):
            return .windowClose(windowID: windowID)

        case .windowRenamed(let windowID, let newName):
            return .windowRenamed(windowID: windowID, newName: newName)

        case .sessionChanged(let sessionID, let name):
            return .sessionChanged(sessionID: sessionID, name: name)

        case .sessionWindowChanged(_, let windowID):
            return .selectWindow(windowID: windowID)

        case .paneExited(let paneID):
            return .paneExited(paneID: paneID)

        case .pasteBufferChanged, .unknown:
            // Accumulate plain lines that arrive between %begin and %end as command output.
            if inBlock { outputAccumulator += line + "\n" }
            return nil
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

    // Quotes a run of non-control bytes as a double-quoted tmux string for use
    // with `send-keys -l`. Caller has already filtered out bytes < 0x20 / 0x7F.
    // UTF-8 high bytes pass through verbatim, so we build a [UInt8] and decode
    // the whole thing once — going via `Character(UnicodeScalar(byte))` would
    // upcast each byte to its Latin-1 codepoint and re-UTF-8-encode, doubling
    // every multibyte sequence on the wire (typed Cyrillic/CJK/emoji corrupted).
    private static func tmuxQuoteBytes<C: Sequence>(_ bytes: C) -> String
        where C.Element == UInt8
    {
        var out: [UInt8] = [0x22]                                  // "
        for byte in bytes {
            switch byte {
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])        // \  → \\
            case 0x22: out.append(contentsOf: [0x5C, 0x22])        // "  → \"
            default:   out.append(byte)
            }
        }
        out.append(0x22)
        return String(decoding: out, as: UTF8.self)
    }

    deinit {
        if childPid > 0 { kill(childPid, SIGTERM) }
        if masterFd >= 0 { close(masterFd) }
    }
}
