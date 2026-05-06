import AppKit

/// Right column: details of the focused session — name, cwd, branch,
/// numbered window strip.
final class SwitcherDetailView: NSView {

    var session: Session? { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session else {
            drawEmpty()
            return
        }
        let pad: CGFloat = 18
        var y = bounds.height - 16

        // SESSION caps + name + cwd
        y = drawTitleRow(s, top: y, padX: pad)
        y -= 6

        // Metadata: branch, status
        y = drawMetadata(s, top: y, padX: pad)
        y -= 18

        // Section: windows
        y = drawSectionHeader("WINDOWS", top: y, padX: pad)
        y -= 4
        y = drawWindows(s, top: y, padX: pad)
    }

    private func drawEmpty() {
        let str = NSAttributedString(string: "no session selected", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: bounds.midX - sz.width / 2,
                             y: bounds.midY - sz.height / 2))
    }

    @discardableResult
    private func drawTitleRow(_ s: Session, top y: CGFloat, padX: CGFloat) -> CGFloat {
        let cap = NSAttributedString(string: "SESSION", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Palette.textMuted,
            .kern: 0.5,
        ])
        let cs = cap.size()
        cap.draw(at: NSPoint(x: padX, y: y - cs.height))

        let name = NSAttributedString(string: s.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold),
            .foregroundColor: Palette.textPrimary,
            .kern: -0.2,
        ])
        let ns = name.size()
        let nameX = padX + cs.width + 10
        name.draw(at: NSPoint(x: nameX, y: y - ns.height + 4))

        if let cwd = s.workspacePath {
            let cwdAttr = NSAttributedString(string: cwd, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let cs2 = cwdAttr.size()
            let cwdX = nameX + ns.width + 10
            let avail = bounds.width - padX - cwdX
            if cs2.width <= avail {
                cwdAttr.draw(at: NSPoint(x: cwdX, y: y - cs2.height + 1))
            } else {
                // truncate
                let truncated = truncate(cwd, font: Palette.monoBody, available: avail)
                let t = NSAttributedString(string: truncated, attributes: [
                    .font: Palette.monoBody,
                    .foregroundColor: Palette.textMuted,
                ])
                t.draw(at: NSPoint(x: cwdX, y: y - cs2.height + 1))
            }
        }

        return y - max(ns.height, cs.height)
    }

    @discardableResult
    private func drawMetadata(_ s: Session, top y: CGFloat, padX: CGFloat) -> CGFloat {
        var x = padX
        let yOut = y

        if let branch = s.branchName {
            x = drawKVPair("branch", branch, x: x, y: yOut, valueColor: Palette.statusWarning)
            x += 14
        }
        x = drawKVPair("status", s.status.rawValue, x: x, y: yOut, valueColor: Palette.textSecondary)
        if !s.claudeSessions.isEmpty {
            x += 14
            let working = s.claudeSessions.filter { $0.status == .working }.count
            let total = s.claudeSessions.count
            x = drawKVPair("claude", "\(working)/\(total)", x: x, y: yOut, valueColor: Palette.statusInfo)
        }

        return yOut - 14
    }

    private func drawKVPair(_ key: String, _ value: String, x: CGFloat, y: CGFloat, valueColor: NSColor) -> CGFloat {
        let k = NSAttributedString(string: key, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textMuted,
        ])
        let ks = k.size()
        k.draw(at: NSPoint(x: x, y: y - ks.height))
        let nx = x + ks.width + 6
        let v = NSAttributedString(string: value, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: valueColor,
        ])
        let vs = v.size()
        v.draw(at: NSPoint(x: nx, y: y - vs.height))
        return nx + vs.width
    }

    @discardableResult
    private func drawSectionHeader(_ text: String, top y: CGFloat, padX: CGFloat) -> CGFloat {
        let str = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: Palette.textMuted,
            .kern: 0.6,
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: padX, y: y - sz.height))
        return y - sz.height - 4
    }

    @discardableResult
    private func drawWindows(_ s: Session, top y: CGFloat, padX: CGFloat) -> CGFloat {
        var x = padX
        var yPos = y - 32
        let pillH: CGFloat = 28
        let gap: CGFloat = 6
        let maxX = bounds.width - padX

        for (i, w) in s.windows.enumerated() {
            let label = "\(i + 1)  \(w.name)"
            let labelStr = NSAttributedString(string: label, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: w.active ? Palette.textPrimary : Palette.textTertiary,
            ])
            let ls = labelStr.size()
            let pillW = ls.width + 18
            if x + pillW > maxX {
                x = padX
                yPos -= pillH + gap
            }
            let pillRect = NSRect(x: x, y: yPos, width: pillW, height: pillH)
            (w.active ? Palette.brandSoft : Palette.surfacePrimary).setFill()
            let path = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            path.fill()
            (w.active ? Palette.brandBorder : Palette.borderSubtle).setStroke()
            path.stroke()
            labelStr.draw(at: NSPoint(x: pillRect.midX - ls.width / 2,
                                      y: pillRect.midY - ls.height / 2))
            x = pillRect.maxX + gap
        }
        return yPos
    }

    private func truncate(_ s: String, font: NSFont, available: CGFloat) -> String {
        let ellipsis = "…"
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var s = s
        while s.count > 4 {
            let candidate = ellipsis + s.suffix(s.count - 1)
            let w = NSAttributedString(string: candidate, attributes: attrs).size().width
            if w <= available { return candidate }
            s.removeFirst()
        }
        return s
    }
}
