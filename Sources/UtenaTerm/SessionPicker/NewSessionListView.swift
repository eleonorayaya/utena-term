import AppKit

/// Generic selectable list view used for both workspace and branch steps.
/// Renders rows with optional visual indicators (currently just text-based).
final class NewSessionListView: NSView {

    var onActivate: (() -> Void)?

    private var items: [ListItem] = []
    private var selectedIndex: Int = 0

    struct ListItem {
        let id: String
        let title: String
        let subtitle: String?
        let isCurrentBranch: Bool  // For branch step, marks the currently checked-out branch
    }

    func update(items: [ListItem], selectedIndex: Int) {
        self.items = items
        self.selectedIndex = min(selectedIndex, max(0, items.count - 1))
        needsDisplay = true
    }

    func getSelectedItem() -> ListItem? {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let next = (selectedIndex + delta + items.count) % items.count
        selectedIndex = next
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hPad: CGFloat = 16
        let vPad: CGFloat = 12
        let rowHeight: CGFloat = 50
        let spacing: CGFloat = 2

        var y = bounds.height - vPad

        for (idx, item) in items.enumerated() {
            let isSelected = (idx == selectedIndex)
            let rowRect = NSRect(
                x: hPad,
                y: y - rowHeight,
                width: bounds.width - 2 * hPad,
                height: rowHeight
            )

            drawRow(item, in: rowRect, selected: isSelected)
            y -= rowHeight + spacing
        }
    }

    private func drawRow(_ item: ListItem, in rect: NSRect, selected: Bool) {
        // Background: brand soft if selected, otherwise transparent
        if selected {
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            Palette.brandSoft.setFill()
            path.fill()
            Palette.brandBorder.setStroke()
            path.stroke()
        }

        let inner = rect.insetBy(dx: 12, dy: 0)

        // Main title
        let titleColor = selected ? Palette.textPrimary : Palette.textSecondary
        let titleStr = NSAttributedString(string: item.title, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: titleColor,
        ])
        let titleSize = titleStr.size()
        let titleY = inner.midY - titleSize.height / 2 + 6
        titleStr.draw(at: NSPoint(x: inner.minX, y: titleY))

        // Subtitle (if present)
        if let subtitle = item.subtitle {
            let subtitleStr = NSAttributedString(string: subtitle, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: Palette.textMuted,
            ])
            let subtitleSize = subtitleStr.size()
            subtitleStr.draw(at: NSPoint(x: inner.minX, y: titleY - subtitleSize.height - 4))
        }

        // Right side: "current" badge if this is the current branch
        if item.isCurrentBranch {
            let badge = NSAttributedString(string: "current", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: Palette.statusSuccess,
            ])
            let badgeSize = badge.size()
            badge.draw(at: NSPoint(x: inner.maxX - badgeSize.width, y: inner.midY - badgeSize.height / 2))
        }
    }
}
