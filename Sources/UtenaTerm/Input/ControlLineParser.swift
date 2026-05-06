import Foundation

enum ControlEvent {
    case beginBlock
    case endBlock
    case errorBlock
    case output(paneID: String, data: Data)
    case layoutChange(windowID: String, layout: String)
    case windowAdd(windowID: String)
    case windowClose(windowID: String)
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

        case "%output":
            guard let paneID = scanner.word() else { return .unknown(line) }
            let encoded = scanner.remainder()
            return .output(paneID: paneID, data: unescapeOctal(encoded))

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

    private func unescapeOctal(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            guard bytes[i] == UInt8(ascii: "\\") else {
                result.append(bytes[i])
                i += 1
                continue
            }
            let next = i + 1
            guard next < bytes.count else {
                result.append(bytes[i])
                i = next
                continue
            }
            if bytes[next] == UInt8(ascii: "\\") {
                result.append(UInt8(ascii: "\\"))
                i = next + 1
            } else if next + 2 < bytes.count,
                      let d1 = octalValue(bytes[next]),
                      let d2 = octalValue(bytes[next + 1]),
                      let d3 = octalValue(bytes[next + 2]) {
                result.append(d1 * 64 + d2 * 8 + d3)
                i = next + 3
            } else {
                result.append(bytes[i])
                i = next
            }
        }
        return Data(result)
    }

    private func octalValue(_ b: UInt8) -> UInt8? {
        guard b >= UInt8(ascii: "0"), b <= UInt8(ascii: "7") else { return nil }
        return b - UInt8(ascii: "0")
    }
}

// MARK: - Helpers

func octalEscape(_ data: Data) -> String {
    var result = ""
    result.reserveCapacity(data.count)
    for byte in data {
        if byte == UInt8(ascii: "\\") {
            result += "\\\\"
        } else if byte >= 0x20 && byte < 0x7F {
            result.append(Character(UnicodeScalar(byte)))
        } else {
            result += String(format: "\\%03o", byte)
        }
    }
    return result
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
