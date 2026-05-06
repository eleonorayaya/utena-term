import AppKit

final class WindowTabRow: NSView {
    var windowIDs: [String] = [] { didSet { if windowIDs != oldValue { needsDisplay = true } } }
    var activeID: String? { didSet { if activeID != oldValue { needsDisplay = true } } }
    var onSelectWindow: ((String) -> Void)?

    private var tabFrames: [(id: String, frame: NSRect)] = []

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.surfaceDeep.setFill()
        bounds.fill()

        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let labelEnd = drawSectionLabel()
        drawSeparator(at: labelEnd)
        let tabsStart = labelEnd + 1
        let hintStart = drawHint()
        drawTabs(in: NSRect(x: tabsStart, y: 0,
                            width: max(0, hintStart - tabsStart - 8),
                            height: bounds.height))
    }

    private func drawSectionLabel() -> CGFloat {
        let label = NSAttributedString(string: "WINDOWS", attributes: [
            .font: Palette.monoTinyCaps,
            .foregroundColor: Palette.textSubtle,
            .kern: 0.6,
        ])
        let sz = label.size()
        label.draw(at: NSPoint(x: 12, y: bounds.midY - sz.height / 2))
        return 12 + sz.width + 12
    }

    private func drawSeparator(at x: CGFloat) {
        Palette.borderSubtle.setFill()
        NSRect(x: x, y: 0, width: 1, height: bounds.height - 1).fill()
    }

    private func drawTabs(in region: NSRect) {
        tabFrames.removeAll(keepingCapacity: true)
        var x = region.minX
        for (i, id) in windowIDs.enumerated() {
            let active = id == activeID
            let label = "\(i + 1)"
            let labelStr = NSAttributedString(string: label, attributes: [
                .font: active ? Palette.monoBodyBold : Palette.monoBody,
                .foregroundColor: active ? Palette.textPrimary : Palette.textTertiary,
            ])
            let labelSize = labelStr.size()
            let tabW = labelSize.width + 28  // generous padding so future names fit
            let tabRect = NSRect(x: x, y: 0, width: tabW, height: bounds.height - 1)
            if tabRect.maxX > region.maxX { break }

            if active {
                Palette.brandSoft.setFill()
                tabRect.fill()
                Palette.brand.setFill()
                NSRect(x: tabRect.minX, y: tabRect.maxY - 1.5, width: tabRect.width, height: 1.5).fill()
            }

            // Right divider between tabs
            Palette.borderSubtle.setFill()
            NSRect(x: tabRect.maxX, y: 0, width: 1, height: bounds.height - 1).fill()

            // Numbered index badge inside the tab
            let badgeW: CGFloat = 14
            let badgeRect = NSRect(x: tabRect.minX + 8, y: bounds.midY - 7,
                                   width: badgeW, height: 14)
            (active ? Palette.brandStrong : Palette.chipBackground).setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3).fill()
            labelStr.draw(at: NSPoint(x: badgeRect.midX - labelSize.width / 2,
                                      y: badgeRect.midY - labelSize.height / 2))

            tabFrames.append((id, tabRect))
            x = tabRect.maxX + 1
        }
    }

    private func drawHint() -> CGFloat {
        let hPad: CGFloat = 12
        var x = bounds.width - hPad

        let new = NSAttributedString(string: "new", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let ns = new.size()
        x -= ns.width
        new.draw(at: NSPoint(x: x, y: bounds.midY - ns.height / 2))
        x -= 6
        x = KbdGlyph.drawTrailing("c", rightAnchor: x, midY: bounds.midY, style: .compact, background: Palette.surfaceBackground)
        x -= 8

        let dot = NSAttributedString(string: "·", attributes: [
            .font: Palette.monoBody, .foregroundColor: Palette.textSubtle,
        ])
        let ds = dot.size()
        x -= ds.width
        dot.draw(at: NSPoint(x: x, y: bounds.midY - ds.height / 2))
        x -= 8

        let jump = NSAttributedString(string: "jump", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let js = jump.size()
        x -= js.width
        jump.draw(at: NSPoint(x: x, y: bounds.midY - js.height / 2))
        x -= 6
        x = KbdGlyph.drawTrailing("9", rightAnchor: x, midY: bounds.midY, style: .compact, background: Palette.surfaceBackground)
        let dash = NSAttributedString(string: "–", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let dsh = dash.size()
        x -= dsh.width
        dash.draw(at: NSPoint(x: x - 2, y: bounds.midY - dsh.height / 2))
        x -= 4
        x = KbdGlyph.drawTrailing("1", rightAnchor: x, midY: bounds.midY, style: .compact, background: Palette.surfaceBackground)
        return x
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = tabFrames.first(where: { $0.frame.contains(p) }) else { return }
        onSelectWindow?(hit.id)
    }
}
