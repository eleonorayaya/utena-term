import Foundation

indirect enum TmuxLayoutNode {
    case leaf(id: String, cols: Int, rows: Int)
    case hsplit([TmuxLayoutNode])   // {} in tmux = vertical divider = side-by-side panes
    case vsplit([TmuxLayoutNode])   // [] in tmux = horizontal divider = stacked panes
}

extension TmuxLayoutNode {
    var cols: Int {
        switch self {
        case .leaf(_, let c, _): return c
        case .hsplit(let ch): return ch.reduce(0) { $0 + $1.cols }
        case .vsplit(let ch): return ch.first?.cols ?? 0
        }
    }

    var rows: Int {
        switch self {
        case .leaf(_, _, let r): return r
        case .vsplit(let ch): return ch.reduce(0) { $0 + $1.rows }
        case .hsplit(let ch): return ch.first?.rows ?? 0
        }
    }

    func leafIDs() -> [String] {
        switch self {
        case .leaf(let id, _, _): return [id]
        case .hsplit(let ch), .vsplit(let ch): return ch.flatMap { $0.leafIDs() }
        }
    }
}

struct TmuxLayoutParser {
    func parse(_ layout: String) throws -> TmuxLayoutNode {
        var s = layout
        // Strip leading checksum (hex digits before first comma at root level)
        if let comma = s.firstIndex(of: ",") {
            let prefix = s[s.startIndex..<comma]
            if prefix.allSatisfy({ $0.isHexDigit }) {
                s = String(s[s.index(after: comma)...])
            }
        }
        var p = Parser(s)
        return try p.parseNode()
    }

    enum ParseError: Error { case unexpected(String) }
}

private struct Parser {
    let s: String
    var i: String.Index

    init(_ s: String) {
        self.s = s
        self.i = s.startIndex
    }

    var current: Character? { i < s.endIndex ? s[i] : nil }

    mutating func advance() {
        guard i < s.endIndex else { return }
        i = s.index(after: i)
    }

    mutating func readUntil(_ stops: Set<Character>) -> Substring {
        let start = i
        while let c = current, !stops.contains(c) { advance() }
        return s[start..<i]
    }

    mutating func expect(_ c: Character) throws {
        guard current == c else {
            throw TmuxLayoutParser.ParseError.unexpected("expected '\(c)' at \(i)")
        }
        advance()
    }

    mutating func parseNode() throws -> TmuxLayoutNode {
        // WxH
        let colStr = readUntil(["x"])
        try expect("x")
        let rowStr = readUntil([","])
        try expect(",")

        // x,y — consume but don't use
        _ = readUntil([","])
        try expect(",")
        _ = readUntil([",", "{", "[", "}", "]"])

        guard let c = current else {
            throw TmuxLayoutParser.ParseError.unexpected("unexpected end of layout string")
        }

        let cols = Int(colStr) ?? 0
        let rows = Int(rowStr) ?? 0

        switch c {
        case "{":
            advance()
            var children: [TmuxLayoutNode] = []
            while current != nil && current != "}" {
                children.append(try parseNode())
                if current == "," { advance() }
            }
            try expect("}")
            return .hsplit(children)

        case "[":
            advance()
            var children: [TmuxLayoutNode] = []
            while current != nil && current != "]" {
                children.append(try parseNode())
                if current == "," { advance() }
            }
            try expect("]")
            return .vsplit(children)

        case ",":
            advance()
            let idStr = readUntil([",", "}", "]"])
            return .leaf(id: "%" + idStr, cols: cols, rows: rows)

        default:
            throw TmuxLayoutParser.ParseError.unexpected("unexpected character '\(c)'")
        }
    }
}
