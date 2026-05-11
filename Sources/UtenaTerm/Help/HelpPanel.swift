import AppKit

protocol HelpKeyHandling: AnyObject {
    func helpKeyDown(_ event: NSEvent) -> Bool
}

/// Floating overlay panel — extends OverlayPanel.
final class HelpPanel: OverlayPanel {
    weak var keyHandler: HelpKeyHandling?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.helpKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ — let the controller decide whether to dismiss.
        if keyHandler?.helpKeyDown(NSEvent.synthesizeEscape()) == true { return }
        super.cancelOperation(sender)
    }
}
