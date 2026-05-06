import AppKit

/// Right column: details of the focused session — name, status pill,
/// workspace, branch, tmux, last used, claude sessions, and error.
final class SwitcherDetailView: NSView {

    var session: Session? { didSet { needsDisplay = true } }
    /// Kept for SwitcherController API compatibility. The detail view now
    /// fills the body when active; visibility (not a border) signals focus.
    var isFocused: Bool = false

    override func draw(_ dirtyRect: NSRect) {
        guard let s = session else {
            drawEmpty()
            return
        }
        let pad: CGFloat = 18
        var y = bounds.height - 16

        // Name + status pill (no SESSION eyebrow)
        y = drawTitleRow(s, top: y, padX: pad)
        y -= 14

        // Section: workspace, branch, tmux, last used
        y = drawMetadataSection(s, top: y, padX: pad)
        y -= 16

        // Section: claude sessions
        if !s.claudeSessions.isEmpty {
            y = drawClaudeSection(s, top: y, padX: pad)
            y -= 16
        }

        // Status error (if any)
        if let err = s.statusError, !err.isEmpty {
            y = drawStatusError(err, top: y, padX: pad)
        }
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
        // Name (20pt semibold, no SESSION eyebrow)
        let name = NSAttributedString(string: s.name, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: Palette.textPrimary,
            .kern: -0.2,
        ])
        let ns = name.size()
        let nameBaselineY = y - ns.height + 4
        name.draw(at: NSPoint(x: padX, y: nameBaselineY))

        // Status pill next to name, vertically centered with the name
        let pillColor = statusPillColor(for: s.status)
        let statusStr = s.status.rawValue
        let statusAttr = NSAttributedString(string: statusStr, attributes: [
            .font: Palette.monoSmall,
            .foregroundColor: Palette.textPrimary,
        ])
        let statusSize = statusAttr.size()
        let pillX = padX + ns.width + 14
        let pillW = statusSize.width + 10
        let pillH = statusSize.height + 4
        // Center pill vertically with the name's center
        let nameCenterY = nameBaselineY + ns.height / 2
        let pillRect = NSRect(x: pillX, y: nameCenterY - pillH / 2, width: pillW, height: pillH)

        pillColor.setFill()
        let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        pillPath.fill()

        statusAttr.draw(at: NSPoint(x: pillX + 5, y: pillRect.midY - statusSize.height / 2))

        return y - ns.height
    }

    @discardableResult
    private func drawMetadataSection(_ s: Session, top y: CGFloat, padX: CGFloat) -> CGFloat {
        var yPos = y

        // WORKSPACE row
        let wsValue = s.workspace?.name ?? "—"
        yPos = drawMetadataRow("WORKSPACE", wsValue, top: yPos, padX: padX)
        yPos -= 10

        // BRANCH row
        let brValue = s.branchName ?? "—"
        yPos = drawMetadataRow("BRANCH", brValue, top: yPos, padX: padX)
        yPos -= 10

        // TMUX row
        let tmuxValue = s.tmuxSessionName ?? "—"
        yPos = drawMetadataRow("TMUX", tmuxValue, top: yPos, padX: padX)
        yPos -= 10

        // LAST USED row
        let lastValue: String
        if let lastUsed = Date.now <= s.lastUsedAt ? nil : s.lastUsedAt {
            lastValue = relativeTime(lastUsed)
        } else {
            lastValue = "—"
        }
        yPos = drawMetadataRow("LAST USED", lastValue, top: yPos, padX: padX)

        return yPos
    }

    @discardableResult
    private func drawMetadataRow(_ label: String, _ value: String, top y: CGFloat, padX: CGFloat) -> CGFloat {
        let labelAttr = NSAttributedString(string: label, attributes: [
            .font: Palette.monoTinyCaps,
            .foregroundColor: Palette.textSubtle,
            .kern: 0.6,
        ])
        let labelSize = labelAttr.size()
        labelAttr.draw(at: NSPoint(x: padX, y: y - labelSize.height))

        let valueColor = value == "—" ? Palette.textMuted : Palette.textPrimary
        let valueAttr = NSAttributedString(string: value, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: valueColor,
        ])
        _ = valueAttr.size()
        valueAttr.draw(at: NSPoint(x: padX, y: y - labelSize.height - 14))

        return y - labelSize.height - 14
    }


    @discardableResult
    private func drawClaudeSection(_ s: Session, top y: CGFloat, padX: CGFloat) -> CGFloat {
        // CLAUDE header
        let header = NSAttributedString(string: "CLAUDE", attributes: [
            .font: Palette.monoTinyCaps,
            .foregroundColor: Palette.textSubtle,
            .kern: 0.6,
        ])
        let headerSize = header.size()
        header.draw(at: NSPoint(x: padX, y: y - headerSize.height))
        var yPos = y - headerSize.height - 10

        // One row per claude session
        for cs in s.claudeSessions {
            let bullet = "•"
            let bulletAttr = NSAttributedString(string: bullet, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.textMuted,
            ])
            let bulletSize = bulletAttr.size()
            bulletAttr.draw(at: NSPoint(x: padX, y: yPos - bulletSize.height))

            let statusColor = claudeStatusColor(for: cs.status)
            let statusAttr = NSAttributedString(string: cs.status.rawValue, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: statusColor,
            ])
            let statusSize = statusAttr.size()
            statusAttr.draw(at: NSPoint(x: padX + bulletSize.width + 6, y: yPos - statusSize.height))

            yPos -= 12
        }

        return yPos
    }

    @discardableResult
    private func drawStatusError(_ error: String, top y: CGFloat, padX: CGFloat) -> CGFloat {
        let icon = NSAttributedString(string: "⚠", attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.statusError,
        ])
        let iconSize = icon.size()
        icon.draw(at: NSPoint(x: padX, y: y - iconSize.height))

        let errorAttr = NSAttributedString(string: error, attributes: [
            .font: Palette.monoBody,
            .foregroundColor: Palette.statusError,
        ])
        let errorSize = errorAttr.size()
        let maxW = bounds.width - padX - iconSize.width - 8
        if errorSize.width <= maxW {
            errorAttr.draw(at: NSPoint(x: padX + iconSize.width + 6, y: y - errorSize.height))
        } else {
            let truncated = truncate(error, font: Palette.monoBody, available: maxW)
            let t = NSAttributedString(string: truncated, attributes: [
                .font: Palette.monoBody,
                .foregroundColor: Palette.statusError,
            ])
            t.draw(at: NSPoint(x: padX + iconSize.width + 6, y: y - errorSize.height))
        }

        return y - max(iconSize.height, errorSize.height)
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

    private func relativeTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func statusPillColor(for status: SessionStatus) -> NSColor {
        switch status {
        case .active: return Palette.statusSuccess
        case .creating, .pending: return Palette.statusWarning
        case .broken: return Palette.statusError
        case .inactive, .archived, .completed, .deleted: return Palette.textMuted
        }
    }

    private func claudeStatusColor(for status: ClaudeSessionStatus) -> NSColor {
        switch status {
        case .needsAttention: return Palette.statusError
        case .working: return Palette.brand
        case .readyForReview: return Palette.statusSuccess
        case .done: return Palette.statusSuccess
        case .idle: return Palette.textMuted
        }
    }
}
