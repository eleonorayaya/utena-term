import AppKit

/// Top header strip: breadcrumb showing the current step in the flow.
/// Example: "NEW SESSION › workspace › branch › name" with the active step highlighted in brand color.
final class NewSessionHeader: NSView {
    enum Step: Int {
        case workspace = 0
        case branch = 1
        case name = 2
    }

    var currentStep: Step = .workspace { didSet { if currentStep != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let hPad: CGFloat = 18
        let yMid = bounds.midY
        var x = hPad

        // "NEW SESSION" label
        let title = NSAttributedString(string: "NEW SESSION", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Palette.brand,
            .kern: 0.4,
        ])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: x, y: yMid - titleSize.height / 2))
        x += titleSize.width

        // Breadcrumb steps
        let steps: [(String, Step)] = [
            ("workspace", .workspace),
            ("branch", .branch),
            ("name", .name),
        ]

        for (label, step) in steps {
            // Separator
            let sep = NSAttributedString(string: " › ", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Palette.textMuted,
            ])
            let sepSize = sep.size()
            sep.draw(at: NSPoint(x: x, y: yMid - sepSize.height / 2))
            x += sepSize.width

            // Step label
            let isActive = step == currentStep
            let stepColor = isActive ? Palette.brand : Palette.textSubtle
            let stepStr = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: isActive ? .semibold : .regular),
                .foregroundColor: stepColor,
            ])
            let stepSize = stepStr.size()
            stepStr.draw(at: NSPoint(x: x, y: yMid - stepSize.height / 2))
            x += stepSize.width
        }
    }
}
