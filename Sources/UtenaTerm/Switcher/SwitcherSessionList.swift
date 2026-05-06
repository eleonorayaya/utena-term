import AppKit

/// Left column: scrollable list of sessions, grouped into sections
/// (♥ needs you / ✦ active / ◌ idle). Each row shows a status dot,
/// session name, branch, attention badge.
final class SwitcherSessionList: NSView {

    var onActivate: (() -> Void)?
    /// When non-nil, the row matching this session id is rendered with a
    /// "press x again to confirm" treatment.
    var confirmKillFor: UInt? { didSet { needsDisplay = true } }

    private var sections: [Section] = []
    private var rowFrames: [(globalIdx: Int, rect: NSRect)] = []
    private var sessions: [Session] = []
    private var selectedIndex: Int = 0
    private var currentName: String = ""

    private struct Section {
        let label: String
        let glyph: String
        let sessions: [Session]
    }

    func update(sessions: [Session], selectedIndex: Int, currentName: String) {
        self.sessions = sessions
        self.selectedIndex = selectedIndex
        self.currentName = currentName
        rebuildSections()
        needsDisplay = true
    }

    private func rebuildSections() {
        var attention: [Session] = []
        var active: [Session] = []
        var idle: [Session] = []
        for s in sessions {
            if s.needsAttention { attention.append(s) }
            else if s.status == .active || s.status == .creating { active.append(s) }
            else { idle.append(s) }
        }
        sections = [
            Section(label: "needs you", glyph: "♥", sessions: attention),
            Section(label: "active",    glyph: "✦", sessions: active),
            Section(label: "idle",      glyph: "◌", sessions: idle),
        ].filter { !$0.sessions.isEmpty }
    }

    override func draw(_ dirtyRect: NSRect) {
        rowFrames.removeAll(keepingCapacity: true)
        let hPad: CGFloat = 10
        var y = bounds.height - 14

        for (sIdx, section) in sections.enumerated() {
            // Section header
            let header = NSAttributedString(
                string: "\(section.glyph)  \(section.label.uppercased())  ·  \(section.sessions.count)",
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                    .foregroundColor: Palette.textMuted,
                    .kern: 0.5,
                ]
            )
            let hs = header.size()
            header.draw(at: NSPoint(x: hPad + 2, y: y - hs.height))
            y -= hs.height + 8

            for s in section.sessions {
                let rowH: CGFloat = 50
                let rowRect = NSRect(x: hPad, y: y - rowH,
                                     width: bounds.width - 2 * hPad, height: rowH)
                // rowFrames.count is the section-display index, which the
                // controller's `selectedIndex` already aligns with — the
                // controller sorts `filtered` by section priority before
                // handing it to us, so the visual order matches.
                let isSelected = rowFrames.count == selectedIndex
                drawRow(s, in: rowRect, focused: isSelected, isCurrent: s.tmuxSessionName == currentName || s.name == currentName)
                rowFrames.append((globalIdx: rowFrames.count, rect: rowRect))
                y -= rowH + 2
            }
            if sIdx < sections.count - 1 { y -= 8 }
        }
    }

    private func drawRow(_ s: Session, in rect: NSRect, focused: Bool, isCurrent: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let pendingKill = (confirmKillFor == s.id)
        if pendingKill {
            Palette.statusError.withAlphaComponent(0.18).setFill()
            path.fill()
            Palette.statusError.withAlphaComponent(0.55).setStroke()
            path.stroke()
        } else if focused {
            Palette.brandSoft.setFill()
            path.fill()
            Palette.brandBorder.setStroke()
            path.stroke()
        }

        let inner = rect.insetBy(dx: 14, dy: 0)
        let dotR: CGFloat = 8
        let dotRect = NSRect(x: inner.minX, y: inner.midY - dotR / 2,
                             width: dotR, height: dotR)
        statusDotColor(for: s, focused: focused).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        // Name + branch
        let name = NSAttributedString(string: s.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: focused ? Palette.textPrimary : Palette.textSecondary,
        ])
        let nameSize = name.size()
        let nameX = dotRect.maxX + 10
        let nameY = inner.midY - nameSize.height / 2 + 6
        name.draw(at: NSPoint(x: nameX, y: nameY))

        // Subtitle: branch + status string
        var sub: [String] = []
        if let branch = s.branchName { sub.append(branch) }
        if isCurrent { sub.append("active") }
        else { sub.append(s.status.rawValue) }
        let subStr = NSAttributedString(string: sub.joined(separator: "  ·  "), attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: Palette.textMuted,
        ])
        let subSize = subStr.size()
        subStr.draw(at: NSPoint(x: nameX, y: nameY - subSize.height - 4))

        // Right side: attention badge or window count
        if s.needsAttention {
            drawAttentionBadge(in: rect, sess: s)
        } else if !s.windows.isEmpty {
            drawWindowCount(in: rect, count: s.windows.count)
        }
    }

    private func statusDotColor(for s: Session, focused: Bool) -> NSColor {
        if s.needsAttention { return Palette.statusError }
        if focused { return Palette.brand }
        switch s.status {
        case .active:   return Palette.statusSuccess
        case .creating, .pending: return Palette.statusInfo
        default: return Palette.textSubtle
        }
    }

    private func drawAttentionBadge(in rect: NSRect, sess: Session) {
        let count = sess.claudeSessions.filter { $0.status == .needsAttention }.count
        let label = count > 0 ? "\(count) need attention" : "needs attention"
        let str = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: Palette.statusError,
        ])
        let sz = str.size()
        let pad: CGFloat = 8
        let badgeRect = NSRect(
            x: rect.maxX - 14 - sz.width - pad * 2,
            y: rect.midY - 9,
            width: sz.width + pad * 2,
            height: 18
        )
        Palette.statusError.withAlphaComponent(0.14).setFill()
        let bp = NSBezierPath(roundedRect: badgeRect, xRadius: 4, yRadius: 4)
        bp.fill()
        Palette.statusError.withAlphaComponent(0.40).setStroke()
        bp.stroke()
        str.draw(at: NSPoint(x: badgeRect.midX - sz.width / 2,
                             y: badgeRect.midY - sz.height / 2))
    }

    private func drawWindowCount(in rect: NSRect, count: Int) {
        let str = NSAttributedString(string: "\(count) win", attributes: [
            .font: Palette.monoSmall,
            .foregroundColor: Palette.textMuted,
        ])
        let sz = str.size()
        str.draw(at: NSPoint(x: rect.maxX - 14 - sz.width,
                             y: rect.midY - sz.height / 2))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard rowFrames.firstIndex(where: { $0.rect.contains(p) }) != nil else { return }
        if event.clickCount >= 2 { onActivate?() }
    }
}
