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

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let cmd = event.modifierFlags.contains(.command)
            let shift = event.modifierFlags.contains(.shift)
            if cmd {
                switch (event.charactersIgnoringModifiers, shift) {
                case ("d", false): splitDelegate?.terminalWindowSplitVertical(); return
                case ("d", true):  splitDelegate?.terminalWindowSplitHorizontal(); return
                case ("[", _):     splitDelegate?.terminalWindowFocusPrev(); return
                case ("]", _):     splitDelegate?.terminalWindowFocusNext(); return
                case ("w", _):     splitDelegate?.terminalWindowClosePane(); return
                default: break
                }
            }
        }
        super.sendEvent(event)
    }
}
