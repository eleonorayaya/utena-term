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

    override func keyDown(with event: NSEvent) {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        guard cmd else { super.keyDown(with: event); return }

        switch (event.charactersIgnoringModifiers, shift) {
        case ("d", false): splitDelegate?.terminalWindowSplitVertical()
        case ("d", true):  splitDelegate?.terminalWindowSplitHorizontal()
        case ("[", _):     splitDelegate?.terminalWindowFocusPrev()
        case ("]", _):     splitDelegate?.terminalWindowFocusNext()
        case ("w", _):     splitDelegate?.terminalWindowClosePane()
        default:           super.keyDown(with: event)
        }
    }
}
