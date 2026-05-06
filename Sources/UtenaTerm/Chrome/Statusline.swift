import AppKit

final class Statusline: NSView {
    var sessionName: String = "" { didSet { if sessionName != oldValue { needsDisplay = true } } }
    var branchName: String? { didSet { if branchName != oldValue { needsDisplay = true } } }
    var attentionNames: [String] = [] { didSet { if attentionNames != oldValue { needsDisplay = true } } }

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
        Palette.surfaceBackground.setFill()
        bounds.fill()

        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let rightX = drawRight()
        var leftX: CGFloat = 0
        leftX = drawSessionPill(at: leftX)
        leftX = drawAttention(after: leftX, maxX: rightX - 12)
        _ = leftX
    }

    // MARK: - Left: slanted session pill with status dot

    private func drawSessionPill(at startX: CGFloat) -> CGFloat {
        guard !sessionName.isEmpty else { return startX }
        let label = NSAttributedString(string: sessionName, attributes: [
            .font: Palette.monoBodyBold,
            .foregroundColor: Palette.textPrimary,
        ])
        let labelSize = label.size()
        let dotR: CGFloat = 6
        let leftPad: CGFloat = 12
        let rightPad: CGFloat = 18  // wider on slanted side
        let slant: CGFloat = 8
        let pillW = leftPad + dotR + 7 + labelSize.width + rightPad
        let pillRect = NSRect(x: startX, y: 0, width: pillW, height: bounds.height - 1)

        let path = NSBezierPath()
        path.move(to: NSPoint(x: pillRect.minX, y: pillRect.minY))
        path.line(to: NSPoint(x: pillRect.maxX - slant, y: pillRect.minY))
        path.line(to: NSPoint(x: pillRect.maxX, y: pillRect.maxY))
        path.line(to: NSPoint(x: pillRect.minX, y: pillRect.maxY))
        path.close()
        Palette.brandSoft.setFill()
        path.fill()

        let dotRect = NSRect(x: startX + leftPad, y: pillRect.midY - dotR / 2,
                             width: dotR, height: dotR)
        Palette.brand.setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        label.draw(at: NSPoint(x: startX + leftPad + dotR + 7,
                               y: pillRect.midY - labelSize.height / 2))
        return pillRect.maxX + 2
    }

    // MARK: - Center: ATTN label + numbered attention chips

    private func drawAttention(after startX: CGFloat, maxX: CGFloat) -> CGFloat {
        guard !attentionNames.isEmpty else { return startX }
        var x = startX + 12

        let label = NSAttributedString(string: "ATTN", attributes: [
            .font: Palette.monoTinyCaps,
            .foregroundColor: Palette.textSubtle,
            .kern: 0.6,
        ])
        let labelSize = label.size()
        if x + labelSize.width >= maxX { return startX }
        label.draw(at: NSPoint(x: x, y: bounds.midY - labelSize.height / 2))
        x += labelSize.width + 10

        for (i, name) in attentionNames.enumerated() {
            let idx = NSAttributedString(string: "\(i + 1)", attributes: [
                .font: Palette.monoTinyCaps,
                .foregroundColor: Palette.textMuted,
            ])
            let idxSize = idx.size()
            let chipRect = NSRect(x: x, y: bounds.midY - 6.5, width: max(13, idxSize.width + 6), height: 13)
            if chipRect.maxX + 60 >= maxX { break }
            Palette.chipBackground.setFill()
            NSBezierPath(roundedRect: chipRect, xRadius: 3, yRadius: 3).fill()
            idx.draw(at: NSPoint(x: chipRect.midX - idxSize.width / 2,
                                 y: chipRect.midY - idxSize.height / 2))
            x = chipRect.maxX + 5

            // Status dot — daemon doesn't expose attention kind yet; use warning tone.
            let dotRect = NSRect(x: x, y: bounds.midY - 2.5, width: 5, height: 5)
            Palette.statusWarning.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            x = dotRect.maxX + 5

            let n = NSAttributedString(string: name, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textSecondary,
            ])
            let ns = n.size()
            if x + ns.width >= maxX { break }
            n.draw(at: NSPoint(x: x, y: bounds.midY - ns.height / 2))
            x += ns.width + 12
        }
        return x
    }

    // MARK: - Right: branch · clock · ⌃b s switcher

    private func drawRight() -> CGFloat {
        let hPad: CGFloat = 14
        var x = bounds.width - hPad

        x = drawSwitcherHint(rightAnchor: x)
        x = drawDot(rightAnchor: x)

        let clock = NSAttributedString(string: Self.clockFormatter.string(from: Date()), attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textTertiary,
        ])
        let cs = clock.size()
        x -= cs.width
        clock.draw(at: NSPoint(x: x, y: bounds.midY - cs.height / 2))
        x -= 8

        if let branch = branchName {
            x = drawDot(rightAnchor: x)
            let b = NSAttributedString(string: branch, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.statusWarning,
            ])
            let bs = b.size()
            x -= bs.width
            b.draw(at: NSPoint(x: x, y: bounds.midY - bs.height / 2))
            x -= 6
            let icon = NSAttributedString(string: "", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textSubtle,
            ])
            let iw = icon.size().width
            x -= iw
            icon.draw(at: NSPoint(x: x, y: bounds.midY - bs.height / 2))
            x -= 8
        }

        return x
    }

    private func drawSwitcherHint(rightAnchor: CGFloat) -> CGFloat {
        var x = rightAnchor
        let label = NSAttributedString(string: "switcher", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let ls = label.size()
        x -= ls.width
        label.draw(at: NSPoint(x: x, y: bounds.midY - ls.height / 2))
        x -= 6
        x = drawKbd("s", rightAnchor: x)
        x = drawKbd("b", rightAnchor: x)
        x = drawKbd("⌃", rightAnchor: x)
        return x
    }

    private func drawKbd(_ s: String, rightAnchor: CGFloat) -> CGFloat {
        let str = NSAttributedString(string: s, attributes: [
            .font: Palette.monoSmallBold,
            .foregroundColor: Palette.textTertiary,
        ])
        let sz = str.size()
        let w = max(16, sz.width + 8)
        let kbdRect = NSRect(x: rightAnchor - w, y: bounds.midY - 7, width: w, height: 14)
        Palette.surfaceDeep.setFill()
        let path = NSBezierPath(roundedRect: kbdRect, xRadius: 3, yRadius: 3)
        path.fill()
        Palette.borderSubtle.setStroke()
        path.stroke()
        str.draw(at: NSPoint(x: kbdRect.midX - sz.width / 2,
                             y: kbdRect.midY - sz.height / 2))
        return kbdRect.minX - 3
    }

    private func drawDot(rightAnchor: CGFloat) -> CGFloat {
        let str = NSAttributedString(string: "·", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let sz = str.size()
        let x = rightAnchor - sz.width
        str.draw(at: NSPoint(x: x, y: bounds.midY - sz.height / 2))
        return x - 8
    }
}
