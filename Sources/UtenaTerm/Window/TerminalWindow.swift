import AppKit

protocol TerminalWindowDelegate: AnyObject {
    func terminalWindowSplitHorizontal()
    func terminalWindowSplitVertical()
    func terminalWindowFocusNext()
    func terminalWindowFocusPrev()
    func terminalWindowClosePane()
    /// Open / dismiss the session switcher overlay (⌃b s or ⌃b p).
    func terminalWindowToggleSwitcher()
    /// Open / dismiss the workspace management overlay (⌃b w).
    func terminalWindowToggleWorkspaces()
    /// Open / dismiss the keyboard help overlay (⌃b ?).
    func terminalWindowToggleHelp()
    /// Create a new tmux window in the focused session (⌃b c).
    func terminalWindowNewWindow()
    /// Jump to window N (1-indexed) in the focused session (⌃b 1 … ⌃b 9).
    func terminalWindowSelectWindow(index: Int)
    /// Move to the next window in the focused session (⌃b n / ⌃b l).
    func terminalWindowNextWindow()
    /// Move to the previous window in the focused session (⌃b h).
    func terminalWindowPrevWindow()
    /// Kill the focused tmux window (⌃b &).
    func terminalWindowKillTmuxWindow()
    /// Toggle zoom on focused pane (⌃b z).
    func terminalWindowToggleZoom()
    /// Rename focused tmux window (⌃b ,).
    func terminalWindowRenameWindow()
}

final class TerminalWindow: NSWindow {
    weak var splitDelegate: TerminalWindowDelegate?
    var windowBackground: PaneAppearance = .default

    private var prefixActive = false
    private var prefixTimer: Timer?
    private static let prefixTimeout: TimeInterval = 1.0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat {

            // 1. Cmd-modified shortcuts (always handled here, even mid-prefix).
            if event.modifierFlags.contains(.command) {
                let shift = event.modifierFlags.contains(.shift)
                switch event.keyCode {
                case KeyMap.Key.d where !shift: splitDelegate?.terminalWindowSplitVertical(); return
                case KeyMap.Key.d where shift:  splitDelegate?.terminalWindowSplitHorizontal(); return
                case KeyMap.Key.n where shift:
                    NSApp.sendAction(#selector(AppDelegate.openTmuxWindow(_:)), to: nil, from: self)
                    return
                case KeyMap.Key.leftBracket:    splitDelegate?.terminalWindowFocusPrev(); return
                case KeyMap.Key.rightBracket:   splitDelegate?.terminalWindowFocusNext(); return
                case KeyMap.Key.w:              splitDelegate?.terminalWindowClosePane(); return
                default: break
                }
            }

            // 2. Tmux-style prefix: ⌃b enters prefix mode; the next keypress
            //    dispatches to a chord-bound action. Mirrors `prefix s`/`prefix p`.
            //    Times out after ~1s so a stray ⌃b doesn't trap the next key.
            let modsOnlyControl = event.modifierFlags.intersection([.control, .option, .command, .shift]) == .control
            if modsOnlyControl, event.keyCode == KeyMap.Key.b, !prefixActive {
                enterPrefix()
                return
            }
            if prefixActive {
                exitPrefix()
                switch event.keyCode {
                case KeyMap.Key.s, KeyMap.Key.p: splitDelegate?.terminalWindowToggleSwitcher(); return
                case KeyMap.Key.w:               splitDelegate?.terminalWindowToggleWorkspaces(); return
                case KeyMap.Key.c:               splitDelegate?.terminalWindowNewWindow();      return
                case KeyMap.Key.n, KeyMap.Key.l: splitDelegate?.terminalWindowNextWindow();     return
                case KeyMap.Key.h:               splitDelegate?.terminalWindowPrevWindow();     return
                case KeyMap.Key.x:               splitDelegate?.terminalWindowClosePane();      return
                case KeyMap.Key.z:               splitDelegate?.terminalWindowToggleZoom();     return
                default: break
                }
                let chars = event.charactersIgnoringModifiers ?? ""
                switch chars {
                case "&":
                    splitDelegate?.terminalWindowKillTmuxWindow()
                    return
                case "%":
                    splitDelegate?.terminalWindowSplitVertical()
                    return
                case "\"":
                    splitDelegate?.terminalWindowSplitHorizontal()
                    return
                case ",":
                    splitDelegate?.terminalWindowRenameWindow()
                    return
                case "?":
                    splitDelegate?.terminalWindowToggleHelp()
                    return
                default: break
                }
                // ⌃b 1 … ⌃b 9 — jump to window N. Match against the
                // unmodified character so ANSI/DVORAK layouts agree.
                if chars.count == 1,
                   let digit = chars.first?.wholeNumberValue,
                   (1 ... 9).contains(digit)
                {
                    splitDelegate?.terminalWindowSelectWindow(index: digit)
                    return
                }
                // Unknown chord — eat it so it doesn't leak to the pane.
                return
            }
        }
        super.sendEvent(event)
    }

    private func enterPrefix() {
        prefixActive = true
        prefixTimer?.invalidate()
        prefixTimer = Timer.scheduledTimer(withTimeInterval: Self.prefixTimeout, repeats: false) { [weak self] _ in
            self?.exitPrefix()
        }
    }

    private func exitPrefix() {
        prefixActive = false
        prefixTimer?.invalidate()
        prefixTimer = nil
    }
}
