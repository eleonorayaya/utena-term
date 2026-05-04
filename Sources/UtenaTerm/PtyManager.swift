import Foundation
import Darwin

// TIOCSWINSZ and TIOCSCTTY may not import via Clang importer on some SDK versions.
private let TIOCSWINSZ_REQ: UInt = 0x80087467
private let TIOCSCTTY_REQ: UInt = 0x20007461

// Swift's Foundation overlay marks fork() unavailable; bind directly to the C symbol.
@_silgen_name("fork") private func _fork() -> pid_t

final class PtyManager {
    var onData: ((Data) -> Void)?

    private var masterFd: Int32 = -1
    private var childPid: pid_t = 0

    func start(cols: UInt16, rows: UInt16) {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        precondition(master >= 0, "posix_openpt failed")
        _ = grantpt(master)
        _ = unlockpt(master)

        let slaveName = String(cString: ptsname(master))
        let slave = open(slaveName, O_RDWR)
        precondition(slave >= 0, "open slave pty failed")

        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ_REQ, &ws)

        let env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"

        let envKeys = ["TERM", "HOME", "SHELL", "PATH", "LANG", "LOGNAME", "USER"]
        var envEntries: [String] = ["TERM=xterm-256color"]
        for key in envKeys where key != "TERM" {
            if let val = env[key] {
                envEntries.append("\(key)=\(val)")
            }
        }

        var argv: ContiguousArray<UnsafeMutablePointer<CChar>?> = [strdup(shell), nil]
        var envp: ContiguousArray<UnsafeMutablePointer<CChar>?> = ContiguousArray(envEntries.map { strdup($0) } + [nil])

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
        precondition(pid >= 0, "fork failed")

        for ptr in argv where ptr != nil { free(ptr) }
        for ptr in envp where ptr != nil { free(ptr) }

        close(slave)
        masterFd = master
        childPid = pid

        let t = Thread { [weak self] in
            Thread.current.name = "pty-read"
            self?.readLoop()
        }
        t.start()
    }

    func resize(cols: UInt16, rows: UInt16) {
        guard masterFd >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ_REQ, &ws)
    }

    func write(_ data: Data) {
        guard masterFd >= 0 else { return }
        data.withUnsafeBytes { rawBuf in
            guard var ptr = rawBuf.baseAddress else { return }
            var remaining = rawBuf.count
            while remaining > 0 {
                let n = Darwin.write(masterFd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    break
                }
                ptr = ptr.advanced(by: n)
                remaining -= n
            }
        }
    }

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(masterFd, &buf, buf.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            let chunk = Data(bytes: buf, count: n)
            DispatchQueue.main.async { [weak self] in
                self?.onData?(chunk)
            }
        }
        DispatchQueue.main.async { [weak self] in
            NotificationCenter.default.post(name: .ptyDidClose, object: self)
        }
    }

    deinit {
        if childPid > 0 { kill(childPid, SIGTERM) }
        if masterFd >= 0 { close(masterFd) }
    }
}

extension Notification.Name {
    static let ptyDidClose = Notification.Name("PtyManagerDidClose")
}
