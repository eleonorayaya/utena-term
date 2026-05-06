import AppKit

/// Top header strip: branding + search field + counts + prefix hint.
final class SwitcherHeader: NSView {
    var totalCount: Int = 0 { didSet { needsDisplay = true } }
    var attentionCount: Int = 0 { didSet { needsDisplay = true } }
    var queryDisplay: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let hPad: CGFloat = 18
        let yMid = bounds.midY

        // Left: ❤ heart glyph + "your sessions" label, brand color, monoBoldCaps
        var x = hPad
        x = drawHeartGlyph(at: x, midY: yMid)
        x += 6
        let brand = NSAttributedString(string: "YOUR SESSIONS", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: Palette.brand,
            .kern: 0.4,
        ])
        let brandSize = brand.size()
        brand.draw(at: NSPoint(x: x, y: yMid - brandSize.height / 2))
        x += brandSize.width + 14

        // Vertical separator
        Palette.border.setFill()
        NSRect(x: x, y: yMid - 8, width: 1, height: 16).fill()
        x += 14

        // Search prompt: "❯ <query>" with blinking-style block cursor
        let prompt = NSAttributedString(string: "❯", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.brandDim,
        ])
        let ps = prompt.size()
        prompt.draw(at: NSPoint(x: x, y: yMid - ps.height / 2))
        x += ps.width + 8

        if !queryDisplay.isEmpty {
            let q = NSAttributedString(string: queryDisplay, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: Palette.textSecondary,
            ])
            let qs = q.size()
            q.draw(at: NSPoint(x: x, y: yMid - qs.height / 2))
            x += qs.width + 4
        }
        // Caret
        Palette.brand.withAlphaComponent(0.85).setFill()
        NSRect(x: x, y: yMid - 7, width: 7, height: 15).fill()

        // Right: counts and prefix hint
        drawRight(midY: yMid)
    }

    private func drawHeartGlyph(at startX: CGFloat, midY: CGFloat) -> CGFloat {
        // Approx the SVG heart from the mockup with a NSBezierPath. 14×14 box.
        let box = NSRect(x: startX, y: midY - 7, width: 14, height: 14)
        let p = NSBezierPath()
        p.move(to: NSPoint(x: box.midX, y: box.minY + 11))
        p.curve(to: NSPoint(x: box.minX + 1.6, y: box.minY + 7),
                controlPoint1: NSPoint(x: box.midX - 2.6, y: box.minY + 14),
                controlPoint2: NSPoint(x: box.minX + 1.6, y: box.minY + 12))
        p.curve(to: NSPoint(x: box.midX, y: box.minY + 1.6),
                controlPoint1: NSPoint(x: box.minX + 1.6, y: box.minY + 4),
                controlPoint2: NSPoint(x: box.minX + 4.5, y: box.minY + 1))
        p.curve(to: NSPoint(x: box.maxX - 1.6, y: box.minY + 7),
                controlPoint1: NSPoint(x: box.maxX - 4.5, y: box.minY + 1),
                controlPoint2: NSPoint(x: box.maxX - 1.6, y: box.minY + 4))
        p.curve(to: NSPoint(x: box.midX, y: box.minY + 11),
                controlPoint1: NSPoint(x: box.maxX - 1.6, y: box.minY + 12),
                controlPoint2: NSPoint(x: box.midX + 2.6, y: box.minY + 14))
        p.close()
        Palette.brand.setFill()
        p.fill()
        return box.maxX
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

        // attention
        if attentionCount > 0 {
            let attnLabel = NSAttributedString(string: " need attention", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let alSize = attnLabel.size()
            x -= alSize.width
            attnLabel.draw(at: NSPoint(x: x, y: midY - alSize.height / 2))
            let attnNum = NSAttributedString(string: "\(attentionCount)", attributes: [
                .font: Palette.monoBodyBold,
                .foregroundColor: Palette.statusWarning,
            ])
            let anSize = attnNum.size()
            x -= anSize.width
            attnNum.draw(at: NSPoint(x: x, y: midY - anSize.height / 2))
            x -= 16
            // separator
            Palette.border.setFill()
            NSRect(x: x, y: midY - 7, width: 1, height: 14).fill()
            x -= 16
        }

        // prefix ⌃ b
        let prefix = NSAttributedString(string: "prefix ", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        x = drawKbdGlyph("b", rightAnchor: x, midY: midY)
        x = drawKbdGlyph("⌃", rightAnchor: x, midY: midY)
        let ps = prefix.size()
        x -= ps.width
        prefix.draw(at: NSPoint(x: x, y: midY - ps.height / 2))
    }

    private func drawKbdGlyph(_ s: String, rightAnchor: CGFloat, midY: CGFloat) -> CGFloat {
        let str = NSAttributedString(string: s, attributes: [
            .font: Palette.monoSmallBold,
            .foregroundColor: Palette.textTertiary,
        ])
        let sz = str.size()
        let w = max(18, sz.width + 10)
        let kbdRect = NSRect(x: rightAnchor - w, y: midY - 8, width: w, height: 16)
        Palette.surfaceTertiary.setFill()
        let path = NSBezierPath(roundedRect: kbdRect, xRadius: 4, yRadius: 4)
        path.fill()
        Palette.borderSubtle.setStroke()
        path.stroke()
        str.draw(at: NSPoint(x: kbdRect.midX - sz.width / 2,
                             y: kbdRect.midY - sz.height / 2))
        return kbdRect.minX - 4
    }
}
