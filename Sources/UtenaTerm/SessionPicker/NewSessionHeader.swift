import AppKit

/// Top header strip: breadcrumb showing the current step in the flow.
/// Example: "NEW SESSION › workspace › branch › name" with the active step highlighted in brand color.
/// Also displays the search query (if non-empty) at the right side.
final class NewSessionHeader: NSView {
    enum Step: Int {
        case workspace = 0
        case branch = 1
        case name = 2
    }

    enum ModeIndicator { case insert, normal, hidden }

    var currentStep: Step = .workspace { didSet { if currentStep != oldValue { needsDisplay = true } } }
    var query: String = "" { didSet { if query != oldValue { needsDisplay = true } } }
    var modeIndicator: ModeIndicator = .insert { didSet { if modeIndicator != oldValue { needsDisplay = true } } }

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

        // Right side: mode pill + query indicator
        let rPad: CGFloat = 18
        var xR = bounds.width - rPad

        // Mode pill (only on the list steps; `enterName` hides it)
        if modeIndicator != .hidden {
            let label = (modeIndicator == .insert) ? "/" : "n"
            let bg: NSColor = (modeIndicator == .insert) ? Palette.brand : Palette.surfaceTertiary
            let fg: NSColor = (modeIndicator == .insert) ? Palette.surfaceDeep : Palette.textPrimary
            let pillStr = NSAttributedString(string: label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: fg,
            ])
            let labelSize = pillStr.size()
            let pillW: CGFloat = max(18, labelSize.width + 10)
            let pillH: CGFloat = 16
            let pillRect = NSRect(x: xR - pillW, y: yMid - pillH / 2, width: pillW, height: pillH)
            bg.setFill()
            NSBezierPath(roundedRect: pillRect, xRadius: 3, yRadius: 3).fill()
            pillStr.draw(at: NSPoint(x: pillRect.midX - labelSize.width / 2,
                                     y: pillRect.midY - labelSize.height / 2))
            xR -= pillW + 8
        }

        // Query text with magnifying glass glyph
        if !query.isEmpty {
            let queryStr = NSAttributedString(string: query, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                .foregroundColor: Palette.textTertiary,
            ])
            let querySize = queryStr.size()
            xR -= querySize.width
            queryStr.draw(at: NSPoint(x: xR, y: yMid - querySize.height / 2))

            xR -= 6  // spacing
            let glyphStr = NSAttributedString(string: "🔍", attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: Palette.textSubtle,
            ])
            let glyphSize = glyphStr.size()
            xR -= glyphSize.width
            glyphStr.draw(at: NSPoint(x: xR, y: yMid - glyphSize.height / 2))
        }
    }
}
