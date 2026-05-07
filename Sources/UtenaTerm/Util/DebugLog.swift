import Foundation

// Minimal stderr logger. Set UTENA_LOG=1 in the environment to enable.
// Use a tag like "tmux" so you can `grep '\[tmux\]'` in the launch terminal.
enum DebugLog {
    private static let enabled: Bool = {
        ProcessInfo.processInfo.environment["UTENA_LOG"] != nil
    }()

    static func log(_ tag: String, _ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[\(tag)] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
