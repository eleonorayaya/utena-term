import AppKit

final class WindowTabRow: NSView {
    var windowIDs: [String] = [] { didSet { needsDisplay = true } }
    var activeID: String? { didSet { needsDisplay = true } }
    var onSelectWindow: ((String) -> Void)?

    private static let tabWidth: CGFloat = 32

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.10, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()

        // Top separator
        NSColor(white: 0.20, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()

        for (i, id) in windowIDs.enumerated() {
            let active = id == activeID
            let tabRect = NSRect(x: CGFloat(i) * Self.tabWidth, y: 0,
                                 width: Self.tabWidth, height: bounds.height - 1)
            if active {
                NSColor(white: 0.18, alpha: 1).setFill()
                NSBezierPath(rect: tabRect).fill()
            }
            let label = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: active ? NSColor.labelColor : NSColor.secondaryLabelColor,
            ])
            let sz = label.size()
            label.draw(at: NSPoint(x: tabRect.midX - sz.width / 2, y: tabRect.midY - sz.height / 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        let idx = Int(x / Self.tabWidth)
        guard idx >= 0, idx < windowIDs.count else { return }
        onSelectWindow?(windowIDs[idx])
    }
}
