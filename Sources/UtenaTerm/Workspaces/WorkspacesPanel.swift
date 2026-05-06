import AppKit

protocol WorkspacesKeyHandling: AnyObject {
    func workspacesKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel — extends OverlayPanel.
final class WorkspacesPanel: OverlayPanel {
    weak var keyHandler: WorkspacesKeyHandling?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.workspacesKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if keyHandler?.workspacesKeyDown(NSEvent.synthesizeEscape()) == true { return }
        super.cancelOperation(sender)
    }
}
