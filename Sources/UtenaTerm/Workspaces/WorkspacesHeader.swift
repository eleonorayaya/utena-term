import AppKit

/// Top header strip: branding + counts + hidden indicator.
final class WorkspacesHeader: NSView {
    var totalCount: Int = 0 { didSet { if totalCount != oldValue { needsDisplay = true } } }
    var hiddenCount: Int = 0 { didSet { if hiddenCount != oldValue { needsDisplay = true } } }
    var showingHidden: Bool = false { didSet { if showingHidden != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let hPad: CGFloat = 18
        let yMid = bounds.midY

        // Left: "WORKSPACES" label
        var x = hPad
        let title = NSAttributedString(string: "WORKSPACES", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Palette.brand,
            .kern: 0.4,
        ])
        let titleSize = title.size()
        title.draw(at: NSPoint(x: x, y: yMid - titleSize.height / 2))
        x += titleSize.width + 14

        // Vertical separator
        Palette.border.setFill()
        NSRect(x: x, y: yMid - 8, width: 1, height: 16).fill()
        x += 14

        // Right: total count + hidden count (if any)
        drawRight(midY: yMid)
    }

    private func drawRight(midY: CGFloat) {
        let hPad: CGFloat = 18
        var x = bounds.width - hPad

        // total
        let totalNum = NSAttributedString(string: "\(totalCount)", attributes: [
            .font: Palette.monoBodyBold,
            .foregroundColor: Palette.textSecondary,
        ])
        let totalLabel = NSAttributedString(string: " total", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textMuted,
        ])
        let tlSize = totalLabel.size()
        x -= tlSize.width
        totalLabel.draw(at: NSPoint(x: x, y: midY - tlSize.height / 2))
        let tnSize = totalNum.size()
        x -= tnSize.width
        totalNum.draw(at: NSPoint(x: x, y: midY - tnSize.height / 2))
        x -= 16

        // hidden count (if any)
        if hiddenCount > 0 && !showingHidden {
            let hiddenLabel = NSAttributedString(string: " hidden", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let hlSize = hiddenLabel.size()
            x -= hlSize.width
            hiddenLabel.draw(at: NSPoint(x: x, y: midY - hlSize.height / 2))
            let hiddenNum = NSAttributedString(string: "+\(hiddenCount)", attributes: [
                .font: Palette.monoBodyBold,
                .foregroundColor: Palette.textTertiary,
            ])
            let hnSize = hiddenNum.size()
            x -= hnSize.width
            hiddenNum.draw(at: NSPoint(x: x, y: midY - hnSize.height / 2))
            x -= 16
            // separator
            Palette.border.setFill()
            NSRect(x: x, y: midY - 7, width: 1, height: 14).fill()
            x -= 16
        }

        // prefix ⌃ b w
        let prefix = NSAttributedString(string: "prefix ", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        x = KbdGlyph.drawTrailing("w", rightAnchor: x, midY: midY, style: .spacious, background: Palette.surfaceTertiary)
        x = KbdGlyph.drawTrailing("b", rightAnchor: x, midY: midY, style: .spacious, background: Palette.surfaceTertiary)
        x = KbdGlyph.drawTrailing("⌃", rightAnchor: x, midY: midY, style: .spacious, background: Palette.surfaceTertiary)
        let ps = prefix.size()
        x -= ps.width
        prefix.draw(at: NSPoint(x: x, y: midY - ps.height / 2))
    }
}
