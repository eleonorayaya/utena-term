import AppKit

indirect enum SplitNode {
    case leaf(TerminalPane)
    case branch(axis: NSUserInterfaceLayoutOrientation, leading: SplitNode, trailing: SplitNode)

    func leaves() -> [TerminalPane] {
        switch self {
        case .leaf(let pane): return [pane]
        case .branch(_, let l, let r): return l.leaves() + r.leaves()
        }
    }

    func contains(pane: TerminalPane) -> Bool {
        leaves().contains { $0 === pane }
    }
}
