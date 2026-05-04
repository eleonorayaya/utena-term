import AppKit

final class SplitManager {
    private(set) var root: SplitNode
    private(set) var focusedPane: TerminalPane
    weak var window: NSWindow?
    var onLastPaneClosed: (() -> Void)?

    init(initialPane: TerminalPane) {
        root = .leaf(initialPane)
        focusedPane = initialPane
    }

    // MARK: - Split

    func split(axis: NSUserInterfaceLayoutOrientation) {
        guard let parentView = focusedPane.view.superview else { return }

        let existingView = focusedPane.view
        let frame = existingView.frame
        let cols = focusedPane.view.gridCols
        let rows = focusedPane.view.gridRows

        let newPane = TerminalPane(cols: cols, rows: rows)
        newPane.view.frame = frame

        let splitView = NSSplitView(frame: frame)
        splitView.isVertical = (axis == .vertical)
        splitView.dividerStyle = .thin
        splitView.autoresizingMask = existingView.autoresizingMask

        if let sv = parentView as? NSSplitView, let idx = sv.subviews.firstIndex(of: existingView) {
            sv.removeArrangedSubview(existingView)
            splitView.addArrangedSubview(existingView)
            splitView.addArrangedSubview(newPane.view)
            sv.insertArrangedSubview(splitView, at: idx)
        } else {
            parentView.replaceSubview(existingView, with: splitView)
            splitView.addArrangedSubview(existingView)
            splitView.addArrangedSubview(newPane.view)
        }

        root = replacing(node: root, pane: focusedPane, with: .branch(axis: axis, leading: .leaf(focusedPane), trailing: .leaf(newPane)))
        setFocus(newPane)
    }

    // MARK: - Close

    func closePane(_ pane: TerminalPane) {
        let allLeaves = root.leaves()
        if allLeaves.count == 1 {
            onLastPaneClosed?()
            return
        }

        guard let sibling = siblingPane(of: pane) else { return }
        let paneView = pane.view
        guard let splitView = paneView.superview as? NSSplitView else { return }
        let siblingView = sibling.view

        guard let grandparent = splitView.superview else { return }
        splitView.removeArrangedSubview(paneView)
        splitView.removeArrangedSubview(siblingView)
        siblingView.frame = splitView.frame
        siblingView.autoresizingMask = splitView.autoresizingMask

        if let gv = grandparent as? NSSplitView, let idx = gv.subviews.firstIndex(of: splitView) {
            gv.removeArrangedSubview(splitView)
            gv.insertArrangedSubview(siblingView, at: idx)
        } else {
            grandparent.replaceSubview(splitView, with: siblingView)
        }

        root = removing(node: root, pane: pane)!
        setFocus(sibling)
    }

    // MARK: - Focus navigation

    func focusNext() {
        let leaves = root.leaves()
        guard let idx = leaves.firstIndex(where: { $0 === focusedPane }) else { return }
        setFocus(leaves[(idx + 1) % leaves.count])
    }

    func focusPrev() {
        let leaves = root.leaves()
        guard let idx = leaves.firstIndex(where: { $0 === focusedPane }) else { return }
        setFocus(leaves[(idx + leaves.count - 1) % leaves.count])
    }

    private func setFocus(_ pane: TerminalPane) {
        focusedPane.view.isActive = false
        focusedPane = pane
        pane.view.isActive = true
        window?.makeFirstResponder(pane.view)
    }

    // MARK: - Tree helpers

    private func siblingPane(of target: TerminalPane) -> TerminalPane? {
        func find(_ node: SplitNode) -> TerminalPane? {
            switch node {
            case .leaf: return nil
            case .branch(_, let l, let r):
                if let deeper = find(l) ?? find(r) { return deeper }
                if l.contains(pane: target) { return r.leaves().first }
                if r.contains(pane: target) { return l.leaves().last }
                return nil
            }
        }
        return find(root)
    }

    private func replacing(node: SplitNode, pane: TerminalPane, with replacement: SplitNode) -> SplitNode {
        switch node {
        case .leaf(let p):
            return p === pane ? replacement : node
        case .branch(let axis, let l, let r):
            return .branch(axis: axis,
                           leading: replacing(node: l, pane: pane, with: replacement),
                           trailing: replacing(node: r, pane: pane, with: replacement))
        }
    }

    private func removing(node: SplitNode, pane: TerminalPane) -> SplitNode? {
        switch node {
        case .leaf(let p):
            return p === pane ? nil : node
        case .branch(let axis, let l, let r):
            let newL = removing(node: l, pane: pane)
            let newR = removing(node: r, pane: pane)
            switch (newL, newR) {
            case (nil, let s?), (let s?, nil): return s
            case (let l?, let r?): return .branch(axis: axis, leading: l, trailing: r)
            case (nil, nil): return nil
            }
        }
    }
}
