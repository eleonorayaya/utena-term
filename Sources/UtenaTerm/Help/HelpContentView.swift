import AppKit

/// Custom view that renders keyboard shortcuts in two columns with sections.
final class HelpContentView: NSView {
    struct Entry {
        let chord: String
        let action: String
    }

    struct Section {
        let title: String
        let items: [Entry]
    }

    private let sections: [Section] = [
        Section(title: "WINDOWS", items: [
            Entry(chord: "⌃b c", action: "new window"),
            Entry(chord: "⌃b ,", action: "rename window"),
            Entry(chord: "⌃b &", action: "kill window"),
            Entry(chord: "⌃b n / ⌃b l", action: "next window"),
            Entry(chord: "⌃b h", action: "previous window"),
            Entry(chord: "⌃b 1 .. 9", action: "jump to window N"),
        ]),
        Section(title: "PANES", items: [
            Entry(chord: "⌃b %", action: "split vertical (left|right)"),
            Entry(chord: "⌃b \"", action: "split horizontal (top/bottom)"),
            Entry(chord: "⌃b z", action: "toggle zoom"),
            Entry(chord: "⌃b x", action: "kill focused pane"),
            Entry(chord: "⌘[ / ⌘]", action: "focus prev / next pane"),
        ]),
        Section(title: "SESSIONS", items: [
            Entry(chord: "⌃b s / p", action: "switcher"),
            Entry(chord: "⌃b ?", action: "this help"),
            Entry(chord: "⌘⇧N", action: "new tmux window"),
        ]),
        Section(title: "IN SWITCHER", items: [
            Entry(chord: "↩", action: "attach"),
            Entry(chord: "c", action: "new session"),
            Entry(chord: "d d", action: "delete (twice)"),
            Entry(chord: "r", action: "repair"),
            Entry(chord: "a", action: "archive"),
            Entry(chord: "⎋", action: "close"),
        ]),
    ]

    private let leftMargin: CGFloat = 24
    private let rightMargin: CGFloat = 24
    private let sectionVPadding: CGFloat = 12
    private let rowHeight: CGFloat = 22
    private let columnGap: CGFloat = 40

    override var isOpaque: Bool { false }

    override func draw(_ rect: CGRect) {
        // Background
        Palette.surfacePrimary.setFill()
        bounds.fill()

        // Render sections
        var y: CGFloat = leftMargin

        for section in sections {
            // Section header
            drawSectionHeader(section.title, at: y)
            y += 18

            // Items
            for item in section.items {
                drawRow(chord: item.chord, action: item.action, at: y)
                y += rowHeight
            }

            y += sectionVPadding
        }
    }

    private func drawSectionHeader(_ title: String, at y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: Palette.monoTinyCaps,
            .foregroundColor: Palette.textSubtle,
        ]
        let str = NSAttributedString(string: title, attributes: attrs)
        let size = str.size()
        str.draw(at: NSPoint(x: leftMargin, y: y - size.height / 2))
    }

    private func drawRow(chord: String, action: String, at y: CGFloat) {
        let chordAttrs: [NSAttributedString.Key: Any] = [
            .font: Palette.monoSmall,
            .foregroundColor: Palette.textPrimary,
        ]
        let chordStr = NSAttributedString(string: chord, attributes: chordAttrs)

        let actionAttrs: [NSAttributedString.Key: Any] = [
            .font: Palette.monoSmall,
            .foregroundColor: Palette.textSecondary,
        ]
        let actionStr = NSAttributedString(string: action, attributes: actionAttrs)

        let chordSize = chordStr.size()
        let actionSize = actionStr.size()

        let midY = y - rowHeight / 2

        // Chord on left
        chordStr.draw(at: NSPoint(x: leftMargin, y: midY - chordSize.height / 2))

        // Action on right
        let actionX = leftMargin + columnGap + 80  // Fixed column for actions
        actionStr.draw(at: NSPoint(x: actionX, y: midY - actionSize.height / 2))
    }

    /// Compute total height needed to render all content.
    func computedHeight() -> CGFloat {
        var height = leftMargin

        for section in sections {
            height += 18  // section header
            height += CGFloat(section.items.count) * rowHeight
            height += sectionVPadding
        }

        height += leftMargin
        return height
    }
}
