import AppKit

/// Left column: scrollable list of pull requests.
final class PullRequestsList: NSView {

    private var allPullRequests: [PullRequest] = []
    private var selectedIndex: Int = 0
    private var rowFrames: [(idx: Int, rect: NSRect)] = []

    func update(pullRequests: [PullRequest], selectedIndex: Int) {
        // Sort: open, draft, merged, closed; secondary by number desc
        let stateOrder: [String: Int] = ["open": 0, "draft": 1, "merged": 2, "closed": 3]
        allPullRequests = pullRequests.sorted { a, b in
            let orderA = stateOrder[a.state] ?? 99
            let orderB = stateOrder[b.state] ?? 99
            if orderA != orderB { return orderA < orderB }
            return a.number > b.number
        }
        self.selectedIndex = min(selectedIndex, max(0, allPullRequests.count - 1))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        rowFrames.removeAll(keepingCapacity: true)
        let hPad: CGFloat = 10
        var y = bounds.height - 14

        if allPullRequests.isEmpty {
            let emptyStr = NSAttributedString(string: "(no pull requests)", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let es = emptyStr.size()
            emptyStr.draw(at: NSPoint(x: hPad + 10, y: y - es.height))
            return
        }

        for (idx, pr) in allPullRequests.enumerated() {
            let rowH: CGFloat = 36
            let rowRect = NSRect(x: hPad, y: y - rowH,
                                width: bounds.width - 2 * hPad, height: rowH)
            let isSelected = idx == selectedIndex
            drawRow(pr, in: rowRect, focused: isSelected)
            rowFrames.append((idx: idx, rect: rowRect))
            y -= rowH + 2
        }
    }

    private func drawRow(_ pr: PullRequest, in rect: NSRect, focused: Bool) {
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        if focused {
            Palette.brandSoft.setFill()
            bgPath.fill()
            Palette.brandBorder.setStroke()
            bgPath.stroke()
        }

        let inner = rect.insetBy(dx: 12, dy: 0)
        let yMid = inner.midY

        // PR number and title (left)
        let numberStr = NSAttributedString(string: "#\(pr.number)", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Palette.textSecondary,
        ])
        let ns = numberStr.size()
        numberStr.draw(at: NSPoint(x: inner.minX, y: yMid - ns.height / 2))

        let titleX = inner.minX + ns.width + 8
        let title = NSAttributedString(string: pr.title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: Palette.textPrimary,
        ])
        let ts = title.size()
        title.draw(at: NSPoint(x: titleX, y: yMid - ts.height / 2))

        // Right side: state, author
        var xR = inner.maxX

        // Author (right-aligned before state)
        let authorColor: NSColor
        let authorStr: String
        if pr.isAssignedToMe {
            authorColor = Palette.brand
            authorStr = "@me"
        } else {
            authorColor = Palette.textTertiary
            authorStr = "@\(pr.authorLogin)"
        }
        let authStr = NSAttributedString(string: authorStr, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: authorColor,
        ])
        let as_ = authStr.size()
        xR -= as_.width
        authStr.draw(at: NSPoint(x: xR, y: yMid - as_.height / 2))
        xR -= 12

        // State badge
        let stateColor = stateColor(for: pr.state)
        let stateStr = NSAttributedString(string: pr.state, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: stateColor,
        ])
        let ss = stateStr.size()
        xR -= ss.width
        stateStr.draw(at: NSPoint(x: xR, y: yMid - ss.height / 2))
    }

    private func stateColor(for state: String) -> NSColor {
        switch state {
        case "open": return Palette.statusSuccess
        case "draft": return Palette.textMuted
        case "merged": return Palette.brand
        case "closed": return Palette.statusError
        default: return Palette.textMuted
        }
    }

    func getSelectedPR() -> PullRequest? {
        guard selectedIndex < allPullRequests.count else { return nil }
        return allPullRequests[selectedIndex]
    }

    func moveSelection(by delta: Int) {
        guard !allPullRequests.isEmpty else { return }
        let next = (selectedIndex + delta + allPullRequests.count) % allPullRequests.count
        selectedIndex = next
        needsDisplay = true
    }
}
