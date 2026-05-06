import AppKit

protocol SwitcherKeyHandling: AnyObject {
    func switcherKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel — keeps the terminal as the key window
/// underneath while the switcher is showing. We override `canBecomeKey`
/// to true so that we still receive keyDown / firstResponder events.
final class SwitcherPanel: OverlayPanel {
    weak var keyHandler: SwitcherKeyHandling?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.switcherKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ — let the controller decide whether to dismiss.
        if keyHandler?.switcherKeyDown(NSEvent.synthesizeEscape()) == true { return }
        super.cancelOperation(sender)
    }
}
