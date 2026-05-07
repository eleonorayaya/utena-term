import AppKit

/// Bottom keybinds row showing actions for the current step in the flow.
final class NewSessionFooter: NSView {
    enum Step: Int {
        case workspace = 0
        case branch = 1
        case mode = 2
        case name = 3
    }

    var currentStep: Step = .workspace { didSet { if currentStep != oldValue { needsDisplay = true } } }
    var isLoading: Bool = false { didSet { if isLoading != oldValue { needsDisplay = true } } }
    var errorMessage: String? { didSet { if errorMessage != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        Palette.surfaceDeep.withAlphaComponent(0.6).setFill()
        bounds.fill()

        // Top hairline
        Palette.borderSubtle.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()

        let yMid = bounds.midY

        // If loading, show "loading..." in center
        if isLoading {
            let loadingText = NSAttributedString(string: "loading...", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let size = loadingText.size()
            loadingText.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: yMid - size.height / 2))
            return
        }

        // If error, show error message in coral color
        if let errorMessage = errorMessage {
            let errorText = NSAttributedString(string: errorMessage, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.statusError,
            ])
            let size = errorText.size()
            errorText.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: yMid - size.height / 2))
            return
        }

        // Show keybinds for current step
        var x: CGFloat = 0
        switch currentStep {
        case .workspace:
            x = drawGroup(label: "NAVIGATE", at: x, items: [
                .k(["↑", "↓"], desc: "move", joinChar: ""),
            ])
            x = drawGroup(label: "FILTER", at: x, items: [
                .k(["type"], desc: "filter"),
            ])
            x = drawGroup(label: "ACTION", at: x, items: [
                .k(["↵"], desc: "select"),
            ])

        case .branch:
            x = drawGroup(label: "NAVIGATE", at: x, items: [
                .k(["↑", "↓"], desc: "move", joinChar: ""),
            ])
            x = drawGroup(label: "FILTER", at: x, items: [
                .k(["type"], desc: "filter"),
            ])
            x = drawGroup(label: "ACTION", at: x, items: [
                .k(["↵"], desc: "select"),
            ])

        case .mode:
            x = drawGroup(label: "NAVIGATE", at: x, items: [
                .k(["↑", "↓"], desc: "navigate", joinChar: ""),
            ])
            x = drawGroup(label: "ACTION", at: x, items: [
                .k(["↵"], desc: "select"),
            ])

        case .name:
            x = drawGroup(label: "ACTION", at: x, items: [
                .k(["↵"], desc: "create"),
            ])
        }

        // Right-anchored: back/cancel
        let hPad: CGFloat = 14
        var xR = bounds.width - hPad
        switch currentStep {
        case .workspace:
            xR = KbdGlyph.drawTrailing("esc", rightAnchor: xR, midY: yMid, style: .spacious, background: Palette.surfaceTertiary)
            let label = NSAttributedString(string: "cancel ", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textSubtle,
            ])
            let lSize = label.size()
            xR -= lSize.width
            label.draw(at: NSPoint(x: xR, y: yMid - lSize.height / 2))

        case .branch, .mode, .name:
            xR = KbdGlyph.drawTrailing("esc", rightAnchor: xR, midY: yMid, style: .spacious, background: Palette.surfaceTertiary)
            let label = NSAttributedString(string: "back ", attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textSubtle,
            ])
            let lSize = label.size()
            xR -= lSize.width
            label.draw(at: NSPoint(x: xR, y: yMid - lSize.height / 2))
        }
    }

    private enum Item {
        case keys([String], desc: String, joinChar: String)
        static func k(_ ks: [String], desc: String, joinChar: String = "") -> Item {
            .keys(ks, desc: desc, joinChar: joinChar)
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
            if case let .keys(ks, desc, joinChar) = item {
                for (i, k) in ks.enumerated() {
                    if i > 0, !joinChar.isEmpty {
                        let sep = NSAttributedString(string: joinChar, attributes: [
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
                    KbdGlyph.draw(in: r, label: k, background: Palette.surfaceTertiary)
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
}
