import Foundation

enum ControlEvent {
    case beginBlock
    case endBlock
    case errorBlock
    case layoutChange(windowID: String, layout: String)
    case windowAdd(windowID: String)
    case windowClose(windowID: String)
    case windowRenamed(windowID: String, newName: String)
    case sessionChanged(sessionID: String, name: String)
    case sessionWindowChanged(sessionID: String, windowID: String)
    case paneExited(paneID: String)
    case pasteBufferChanged
    case unknown(String)
}

struct ControlLineParser {
    func parse(_ line: String) -> ControlEvent {
        var scanner = Scanner(line)
        guard let keyword = scanner.word() else { return .unknown(line) }

        switch keyword {
        case "%begin":
            return .beginBlock

        case "%end":
            return .endBlock

        case "%error":
            return .errorBlock

        // %output is intercepted at the byte level by TmuxControlSession before
        // reaching this string-based parser — see handleLine's fast path.

        case "%layout-change":
            guard let windowID = scanner.word(),
                  let layout = scanner.word() else { return .unknown(line) }
            return .layoutChange(windowID: windowID, layout: layout)

        case "%window-add":
            guard let windowID = scanner.word() else { return .unknown(line) }
            return .windowAdd(windowID: windowID)

        case "%window-close":
            guard let windowID = scanner.word() else { return .unknown(line) }
            return .windowClose(windowID: windowID)

        case "%window-renamed":
            guard let windowID = scanner.word(),
                  let newName = scanner.word() else { return .unknown(line) }
            return .windowRenamed(windowID: windowID, newName: newName)

        case "%session-changed":
            guard let sessionID = scanner.word(),
                  let name = scanner.word() else { return .unknown(line) }
            return .sessionChanged(sessionID: sessionID, name: name)

        case "%session-window-changed":
            guard let sessionID = scanner.word(),
                  let windowID = scanner.word() else { return .unknown(line) }
            return .sessionWindowChanged(sessionID: sessionID, windowID: windowID)

        case "%pane-exited":
            guard let paneID = scanner.word() else { return .unknown(line) }
            return .paneExited(paneID: paneID)

        case "%paste-buffer-changed":
            return .pasteBufferChanged

        default:
            return .unknown(line)
        }
    }

    /// Reverses tmux's `vis_data_buf` escaping in `%output` payloads: `\\` → byte
    /// 0x5C, `\NNN` (3-digit octal) → that byte; everything else passes through.
    /// Stays in bytes throughout so binary pane content (UTF-8 multibyte, ESC
    /// sequences) survives untouched.
    static func unescapeOctal<C: RandomAccessCollection>(_ bytes: C) -> Data
        where C.Element == UInt8, C.Index == Int
    {
        var result = Data()
        result.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        let end = bytes.endIndex
        while i < end {
            guard bytes[i] == 0x5C, i + 1 < end else {
                result.append(bytes[i])
                i += 1
                continue
            }
            let next = bytes[i + 1]
            if next == 0x5C {
                result.append(0x5C)
                i += 2
            } else if i + 3 < end,
                      let d1 = octalValue(next),
                      let d2 = octalValue(bytes[i + 2]),
                      let d3 = octalValue(bytes[i + 3]) {
                result.append(d1 &* 64 &+ d2 &* 8 &+ d3)
                i += 4
            } else {
                result.append(bytes[i])
                i += 1
            }
        }
        return result
    }

    private static func octalValue(_ b: UInt8) -> UInt8? {
        (0x30 ... 0x37).contains(b) ? b - 0x30 : nil
    }
}

private struct Scanner {
    private let s: String
    private var i: String.Index

    init(_ s: String) {
        self.s = s
        self.i = s.startIndex
    }

    mutating func word() -> String? {
        guard i < s.endIndex else { return nil }
        let start = i
        while i < s.endIndex && s[i] != " " { i = s.index(after: i) }
        let token = String(s[start..<i])
        if i < s.endIndex { i = s.index(after: i) }
        return token.isEmpty ? nil : token
    }

    func remainder() -> String {
        guard i < s.endIndex else { return "" }
        return String(s[i...])
    }
}
