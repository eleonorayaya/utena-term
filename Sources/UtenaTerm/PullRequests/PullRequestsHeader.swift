import AppKit

/// Top header strip for pull requests overlay.
final class PullRequestsHeader: NSView {
    var workspaceName: String = "" { didSet { if workspaceName != oldValue { needsDisplay = true } } }
    var isLoading: Bool = false { didSet { if isLoading != oldValue { needsDisplay = true } } }
    var errorMessage: String? { didSet { if errorMessage != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        // Bottom hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let hPad: CGFloat = 18
        let yMid = bounds.midY

        // Left: "PULL REQUESTS" label
        var x = hPad
        let title = NSAttributedString(string: "PULL REQUESTS", attributes: [
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

        // Workspace name or status
        if let err = errorMessage {
            let errStr = NSAttributedString(string: "error: \(err)", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.statusError,
            ])
            let es = errStr.size()
            errStr.draw(at: NSPoint(x: x, y: yMid - es.height / 2))
        } else if isLoading {
            let loadStr = NSAttributedString(string: "loading...", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let ls = loadStr.size()
            loadStr.draw(at: NSPoint(x: x, y: yMid - ls.height / 2))
        } else if !workspaceName.isEmpty {
            let wsStr = NSAttributedString(string: workspaceName, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textSecondary,
            ])
            let ws = wsStr.size()
            wsStr.draw(at: NSPoint(x: x, y: yMid - ws.height / 2))
        }

        // Right: prefix ⌃ b P
        let prefix = NSAttributedString(string: "prefix ", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.textSubtle,
        ])
        var xR = bounds.width - hPad
        xR = KbdGlyph.drawTrailing("P", rightAnchor: xR, midY: yMid, style: .spacious, background: Palette.surfaceTertiary)
        xR = KbdGlyph.drawTrailing("b", rightAnchor: xR, midY: yMid, style: .spacious, background: Palette.surfaceTertiary)
        xR = KbdGlyph.drawTrailing("⌃", rightAnchor: xR, midY: yMid, style: .spacious, background: Palette.surfaceTertiary)
        let ps = prefix.size()
        xR -= ps.width
        prefix.draw(at: NSPoint(x: xR, y: yMid - ps.height / 2))
    }
}
