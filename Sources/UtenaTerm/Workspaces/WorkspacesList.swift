import AppKit

/// Left column: scrollable list of workspaces.
final class WorkspacesList: NSView {

    var confirmDeleteFor: UInt? { didSet { needsDisplay = true } }

    private var visibleWorkspaces: [Workspace] = []
    private var selectedIndex: Int = 0
    private var rowFrames: [(globalIdx: Int, rect: NSRect)] = []
    private var showHidden: Bool = false

    func update(workspaces: [Workspace], selectedIndex: Int, showHidden: Bool) {
        self.showHidden = showHidden
        // Visible first, then hidden if showHidden is true
        let visible = workspaces.filter { !$0.isHidden }
        let hidden = workspaces.filter { $0.isHidden }
        visibleWorkspaces = showHidden ? (visible + hidden) : visible
        self.selectedIndex = min(selectedIndex, max(0, visibleWorkspaces.count - 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        rowFrames.removeAll(keepingCapacity: true)
        let hPad: CGFloat = 10
        var y = bounds.height - 14

        // Sections: visible, then hidden (if shown)
        let visible = visibleWorkspaces.filter { !$0.isHidden }
        let hidden = visibleWorkspaces.filter { $0.isHidden }

        if !visible.isEmpty {
            y = drawSection(label: "WORKSPACES", workspaces: visible, startY: y, padX: hPad)
            if showHidden && !hidden.isEmpty {
                y -= 8
            }
        }

        if showHidden && !hidden.isEmpty {
            y = drawSection(label: "HIDDEN", workspaces: hidden, startY: y, padX: hPad)
        }
    }

    private func drawSection(label: String, workspaces: [Workspace], startY: CGFloat, padX: CGFloat) -> CGFloat {
        let header = NSAttributedString(
            string: "\(label)  ·  \(workspaces.count)",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: Palette.textMuted,
                .kern: 0.5,
            ]
        )
        let hs = header.size()
        var y = startY
        header.draw(at: NSPoint(x: padX + 2, y: y - hs.height))
        y -= hs.height + 8

        for ws in workspaces {
            let rowH: CGFloat = 48
            let rowRect = NSRect(x: padX, y: y - rowH,
                                width: bounds.width - 2 * padX, height: rowH)
            let isSelected = rowFrames.count == selectedIndex
            drawRow(ws, in: rowRect, focused: isSelected)
            rowFrames.append((globalIdx: rowFrames.count, rect: rowRect))
            y -= rowH + 2
        }

        return y
    }

    private func drawRow(_ ws: Workspace, in rect: NSRect, focused: Bool) {
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let pendingDelete = (confirmDeleteFor == ws.id)
        if pendingDelete {
            Palette.statusError.withAlphaComponent(0.18).setFill()
            bgPath.fill()
            Palette.statusError.withAlphaComponent(0.55).setStroke()
            bgPath.stroke()
        } else if focused {
            Palette.brandSoft.setFill()
            bgPath.fill()
            Palette.brandBorder.setStroke()
            bgPath.stroke()
        }

        let inner = rect.insetBy(dx: 14, dy: 0)
        let yMid = inner.midY

        // Workspace name (left)
        let name = NSAttributedString(string: ws.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Palette.textPrimary,
        ])
        let ns = name.size()
        name.draw(at: NSPoint(x: inner.minX, y: yMid - ns.height / 2))

        // Path (right-aligned, secondary text)
        let pathStr = NSAttributedString(string: ws.path, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textTertiary,
        ])
        let ps = pathStr.size()
        pathStr.draw(at: NSPoint(x: inner.maxX - ps.width, y: yMid - ps.height / 2))

        // Delete confirmation indicator
        if pendingDelete {
            let confirm = NSAttributedString(string: "press d again", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: Palette.statusError,
            ])
            let cs = confirm.size()
            confirm.draw(at: NSPoint(x: inner.midX - cs.width / 2,
                                    y: yMid - 14 - cs.height / 2))
        }
    }
}
