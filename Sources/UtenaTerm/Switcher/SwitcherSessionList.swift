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

        // Right side: status badge (priority order), or attention badge, or window count
        if let badge = statusBadge(for: s) {
            drawStatusBadge(in: rect, badge: badge)
        } else if s.needsAttention {
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

    private struct StatusBadge {
        let label: String
        let color: NSColor
    }

    /// Determine the highest-priority applicable status badge.
    /// Priority order:
    /// 1. broken → BROKEN (red)
    /// 2. creating → CREATING (warning/yellow)
    /// 3. aggregatedClaudeStatus:
    ///    - needsAttention → ATTN (red)
    ///    - working → WORKING (brand/pink)
    ///    - readyForReview → REVIEW (green)
    ///    - done → DONE (muted)
    ///    - idle → no badge
    /// 4. archived/completed/inactive → status name (muted)
    private func statusBadge(for s: Session) -> StatusBadge? {
        if s.status == .broken {
            return StatusBadge(label: "BROKEN", color: Palette.statusError)
        }
        if s.status == .creating {
            return StatusBadge(label: "CREATING", color: Palette.statusWarning)
        }
        if let aggregated = s.aggregatedClaudeStatus {
            switch aggregated {
            case .needsAttention:
                return StatusBadge(label: "ATTN", color: Palette.statusError)
            case .working:
                return StatusBadge(label: "WORKING", color: Palette.brand)
            case .readyForReview:
                return StatusBadge(label: "REVIEW", color: Palette.statusSuccess)
            case .done:
                return StatusBadge(label: "DONE", color: Palette.textMuted)
            case .idle:
                return nil  // no badge for idle
            }
        }
        // Inactive/archived/completed sessions get a muted badge
        switch s.status {
        case .archived:
            return StatusBadge(label: "ARCHIVED", color: Palette.textMuted)
        case .completed:
            return StatusBadge(label: "COMPLETED", color: Palette.textMuted)
        case .inactive:
            return StatusBadge(label: "INACTIVE", color: Palette.textMuted)
        default:
            return nil
        }
    }

    private func drawStatusBadge(in rect: NSRect, badge: StatusBadge) {
        let label = NSAttributedString(string: badge.label, attributes: [
            .font: Palette.monoSmall,
            .foregroundColor: textColorForBackground(badge.color),
        ])
        let labelSize = label.size()
        let hPad: CGFloat = 4
        let badgeRect = NSRect(
            x: rect.maxX - 14 - labelSize.width - hPad * 2,
            y: rect.midY - 8,
            width: labelSize.width + hPad * 2,
            height: 16
        )

        let path = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
        badge.color.setFill()
        path.fill()

        label.draw(at: NSPoint(x: badgeRect.midX - labelSize.width / 2,
                               y: badgeRect.midY - labelSize.height / 2))
    }

    /// Determine text color for a background color: bright colors get dark text,
    /// dim colors get light text.
    private func textColorForBackground(_ bgColor: NSColor) -> NSColor {
        let srgb = bgColor.usingColorSpace(.sRGB) ?? bgColor
        // Simple luminance heuristic: bright colors (e.g., mint, yellow) get dark text;
        // muted/dark colors get light text.
        let lum = 0.299 * srgb.redComponent + 0.587 * srgb.greenComponent + 0.114 * srgb.blueComponent
        if lum > 0.6 {
            return Palette.surfaceDeep  // dark text on bright bg
        } else {
            return Palette.textPrimary  // light text on dark bg
        }
    }
}
