import AppKit

/// Bottom keybinds row for pull requests overlay.
final class PullRequestsFooter: NSView {

    override func draw(_ dirtyRect: NSRect) {
        Palette.surfaceDeep.withAlphaComponent(0.6).setFill()
        bounds.fill()

        // Top hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let yMid = bounds.midY

        // Left groups
        var x: CGFloat = 0
        x = drawGroup(label: "NAVIGATE", at: x, items: [
            .k(["↑", "↓"], desc: "up/down"),
            .k(["j", "k"], desc: "vim"),
        ])
        x = drawGroup(label: "PR", at: x, items: [
            .k(["↩"], desc: "open in browser"),
            .k(["o"], desc: "open"),
        ])

        // Right-anchored: esc
        let hPad: CGFloat = 14
        var xR = bounds.width - hPad
        xR = KbdGlyph.drawTrailing("esc", rightAnchor: xR, midY: yMid,
                                   style: .spacious, background: Palette.surfaceTertiary)
    }

    private enum Item {
        case keys([String], desc: String)
        static func k(_ ks: [String], desc: String) -> Item {
            .keys(ks, desc: desc)
        }
    }

    private func drawGroup(label: String, at startX: CGFloat, items: [Item]) -> CGFloat {
        let yMid = bounds.midY
        var x = startX

        let lbl = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Palette.textSubtle,
            .kern: 0.6,
        ])
        let ls = lbl.size()
        x += 14
        lbl.draw(at: NSPoint(x: x, y: yMid - ls.height / 2))
        x += ls.width + 12

        for item in items {
            if case let .keys(ks, desc) = item {
                for (i, k) in ks.enumerated() {
                    if i > 0 {
                        let sep = NSAttributedString(string: "/", attributes: [
                            .font: Palette.monoBody,
                            .foregroundColor: Palette.textSubtle,
                        ])
                        let ss = sep.size()
                        sep.draw(at: NSPoint(x: x, y: yMid - ss.height / 2))
                        x += ss.width + 4
                    }
                    let r = NSRect(x: x, y: yMid - 8,
                                   width: max(18, k.size(withAttributes: [.font: Palette.monoSmallBold]).width + 10),
                                   height: 16)
                    drawKbdRect(r, label: k)
                    x = r.maxX + 4
                }
                let d = NSAttributedString(string: desc, attributes: [
                    .font: Palette.monoBody,
                    .foregroundColor: Palette.textMuted,
                ])
                let ds = d.size()
                x += 4
                d.draw(at: NSPoint(x: x, y: yMid - ds.height / 2))
                x += ds.width + 14
            }
        }

        x += 6
        // Right divider
        Palette.borderSubtle.setFill()
        NSRect(x: x, y: 8, width: 1, height: bounds.height - 16).fill()
        x += 1
        return x
    }

    private func drawKbdRect(_ r: NSRect, label: String) {
        KbdGlyph.draw(in: r, label: label, background: Palette.surfaceTertiary)
    }
}
