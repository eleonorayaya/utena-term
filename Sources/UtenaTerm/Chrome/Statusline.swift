import AppKit

final class Statusline: NSView {
    var sessionName: String = "" { didSet { needsDisplay = true } }
    var branchName: String? { didSet { needsDisplay = true } }
    var attentionNames: [String] = [] { didSet { needsDisplay = true } }

    private var timer: Timer?

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 26)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedHue: 0.83, saturation: 0.08, brightness: 0.20, alpha: 1).setFill()
        NSBezierPath(rect: bounds).fill()

        // Top separator
        NSColor(white: 0.28, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)).fill()

        let hPad: CGFloat = 10
        var leftX = hPad
        var rightX = bounds.width - hPad

        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let rightItems: [String] = [
            branchName.map { " \($0)" },
            Self.clockFormatter.string(from: Date()),
            "⌃b p",
        ].compactMap { $0 }

        for item in rightItems.reversed() {
            let str = NSAttributedString(string: item, attributes: dimAttrs)
            let sz = str.size()
            rightX -= sz.width
            str.draw(at: NSPoint(x: rightX, y: bounds.midY - sz.height / 2))
            rightX -= 8
        }

        if !sessionName.isEmpty {
            let pillAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let label = NSAttributedString(string: sessionName, attributes: pillAttrs)
            let sz = label.size()
            let pillRect = NSRect(x: leftX, y: bounds.midY - 9, width: sz.width + 12, height: 18)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
            NSColor(calibratedHue: 0.83, saturation: 0.35, brightness: 0.55, alpha: 1).setFill()
            pill.fill()
            label.draw(at: NSPoint(x: leftX + 6, y: pillRect.minY + (18 - sz.height) / 2))
            leftX += pillRect.width + 10
        }

        let chipAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor(calibratedRed: 1, green: 0.6, blue: 0.2, alpha: 1),
        ]
        for name in attentionNames {
            let chip = NSAttributedString(string: "[\(name)]", attributes: chipAttrs)
            let sz = chip.size()
            chip.draw(at: NSPoint(x: leftX, y: bounds.midY - sz.height / 2))
            leftX += sz.width + 6
        }
    }
}
