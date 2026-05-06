import AppKit

/// Renders a keyboard-glyph "chip" — a small rounded rectangle with a
/// monospace label inside (e.g. ⌃ b s). Statusline, WindowTabRow,
/// SwitcherHeader, and SwitcherFooter all need this; this is the single
/// source of truth for the visual treatment.
enum KbdGlyph {

    /// Visual sizing variants — tighter `compact` for inline statusline
    /// hints, taller `spacious` for the switcher header/footer.
    enum Style {
        case compact   // 14pt height, 3pt radius — for thin status rows
        case spacious  // 16pt height, 4pt radius — for switcher chrome

        var height: CGFloat       { self == .compact ? 14 : 16 }
        var cornerRadius: CGFloat { self == .compact ? 3 : 4 }
        var minWidth: CGFloat     { self == .compact ? 16 : 18 }
        var horizontalPad: CGFloat { self == .compact ? 8 : 10 }
    }

    /// Draws right-aligned at `rightAnchor` (a typical use case in
    /// statusline rows). Returns the new x-cursor (with built-in
    /// inter-glyph gap subtracted).
    @discardableResult
    static func drawTrailing(
        _ label: String,
        rightAnchor: CGFloat,
        midY: CGFloat,
        style: Style,
        background: NSColor
    ) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Palette.monoSmallBold,
            .foregroundColor: Palette.textTertiary,
        ]
        let labelStr = NSAttributedString(string: label, attributes: attrs)
        let labelSize = labelStr.size()
        let width = max(style.minWidth, labelSize.width + style.horizontalPad)
        let rect = NSRect(x: rightAnchor - width, y: midY - style.height / 2,
                          width: width, height: style.height)
        drawChipPath(rect, background: background)
        labelStr.draw(at: NSPoint(x: rect.midX - labelSize.width / 2,
                                  y: rect.midY - labelSize.height / 2))
        return rect.minX - 4
    }

    /// Draws into an explicit rect (for footer-style fixed-position chips).
    static func draw(in rect: NSRect, label: String, background: NSColor, cornerRadius: CGFloat = 4) {
        drawChipPath(rect, background: background, cornerRadius: cornerRadius)
        let str = NSAttributedString(string: label, attributes: [
            .font: Palette.monoSmallBold,
            .foregroundColor: Palette.textTertiary,
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: rect.midX - sz.width / 2,
                             y: rect.midY - sz.height / 2))
    }

    private static func drawChipPath(_ rect: NSRect, background: NSColor, cornerRadius: CGFloat? = nil) {
        let r = cornerRadius ?? 4
        let path = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
        background.setFill()
        path.fill()
        Palette.borderSubtle.setStroke()
        path.stroke()
    }
}
