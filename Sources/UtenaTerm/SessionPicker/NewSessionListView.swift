import AppKit

/// Generic selectable list view used for both workspace and branch steps.
/// Renders rows with optional visual indicators (currently just text-based).
/// Supports scrolling via an internal NSScrollView.
final class NewSessionListView: NSView {

    var onActivate: (() -> Void)?

    private let scrollView = NSScrollView()
    private let rowsView = RowsView()

    struct ListItem {
        let id: String
        let title: String
        let subtitle: String?
        let isCurrentBranch: Bool  // For branch step, marks the currently checked-out branch
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScrollView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScrollView()
    }

    private func setupScrollView() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true

        rowsView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = rowsView

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            rowsView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            rowsView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            rowsView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])
    }

    func update(items: [ListItem], selectedIndex: Int) {
        rowsView.items = items
        rowsView.selectedIndex = min(selectedIndex, max(0, items.count - 1))
        rowsView.invalidateIntrinsicContentSize()
        rowsView.needsLayout = true
        rowsView.needsDisplay = true
        scrollSelectedToVisible()
    }

    func getSelectedItem() -> ListItem? {
        return rowsView.getSelectedItem()
    }

    func move(by delta: Int) {
        rowsView.move(by: delta)
        scrollSelectedToVisible()
    }

    private func scrollSelectedToVisible() {
        guard !rowsView.items.isEmpty else { return }
        let i = rowsView.selectedIndex
        let rh = rowsView.rowHeight + rowsView.spacing
        let y = rowsView.vPad + CGFloat(i) * rh
        let rect = NSRect(x: 0, y: y, width: 10, height: rowsView.rowHeight)
        rowsView.scrollToVisible(rect)
    }

    // MARK: - Inner RowsView

    private final class RowsView: NSView {
        var items: [ListItem] = []
        var selectedIndex: Int = 0

        let rowHeight: CGFloat = 50
        let spacing: CGFloat = 2
        let vPad: CGFloat = 12
        let hPad: CGFloat = 16

        override var intrinsicContentSize: NSSize {
            let h = vPad * 2 + CGFloat(items.count) * (rowHeight + spacing) - (items.isEmpty ? 0 : spacing)
            return NSSize(width: NSView.noIntrinsicMetric, height: max(h, 0))
        }

        override var isFlipped: Bool { true }

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
            var y = vPad

            for (idx, item) in items.enumerated() {
                let isSelected = (idx == selectedIndex)
                let rowRect = NSRect(
                    x: hPad,
                    y: y,
                    width: bounds.width - 2 * hPad,
                    height: rowHeight
                )

                drawRow(item, in: rowRect, selected: isSelected)
                y += rowHeight + spacing
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
}
