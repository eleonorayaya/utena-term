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
        if event.type == .keyDown, event.modifierFlags.contains(.command) {
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 2 where !shift: splitDelegate?.terminalWindowSplitVertical(); return   // D
            case 2 where shift:  splitDelegate?.terminalWindowSplitHorizontal(); return // Shift+D
            case 33:             splitDelegate?.terminalWindowFocusPrev(); return       // [
            case 30:             splitDelegate?.terminalWindowFocusNext(); return       // ]
            case 13:             splitDelegate?.terminalWindowClosePane(); return       // W
            default: break
            }
        }
        super.sendEvent(event)
    }
}
