import AppKit

protocol NewSessionKeyHandling: AnyObject {
    func newSessionKeyDown(_ event: NSEvent) -> Bool
}

/// Floating overlay panel for the new-session multi-step flow.
/// Uses the translucent overlay-panel chrome (HUD blur, 20pt corners).
final class NewSessionPanel: OverlayPanel {
    weak var keyHandler: NewSessionKeyHandling?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.newSessionKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ — let the controller decide whether to dismiss or go back.
        if keyHandler?.newSessionKeyDown(NSEvent.synthesizeEscape()) == true { return }
        super.cancelOperation(sender)
    }
}
