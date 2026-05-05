import AppKit

protocol TerminalWindowDelegate: AnyObject {
    func terminalWindowSplitHorizontal()
    func terminalWindowSplitVertical()
    func terminalWindowFocusNext()
    func terminalWindowFocusPrev()
    func terminalWindowClosePane()
}

final class TerminalWindow: NSWindow {
    weak var splitDelegate: TerminalWindowDelegate?
    var windowBackground: PaneAppearance = .default

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.isARepeat, event.modifierFlags.contains(.command) {
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
        super.sendEvent(event)
    }
}
