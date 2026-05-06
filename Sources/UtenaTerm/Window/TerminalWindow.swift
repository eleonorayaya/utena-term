import AppKit

protocol TerminalWindowDelegate: AnyObject {
    func terminalWindowSplitHorizontal()
    func terminalWindowSplitVertical()
    func terminalWindowFocusNext()
    func terminalWindowFocusPrev()
    func terminalWindowClosePane()
    /// Open / dismiss the session switcher overlay (⌃b s or ⌃b p).
    func terminalWindowToggleSwitcher()
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
                case KeyMap.Key.s, KeyMap.Key.p:
                    splitDelegate?.terminalWindowToggleSwitcher()
                    return
                default:
                    // Unknown chord — eat the keypress so it doesn't leak to
                    // the terminal. tmux behaves the same way.
                    return
                }
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
