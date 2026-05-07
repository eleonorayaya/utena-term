import AppKit

protocol PullRequestsKeyHandling: AnyObject {
    func pullRequestsKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel for pull requests — extends OverlayPanel.
final class PullRequestsPanel: OverlayPanel {
    weak var keyHandler: PullRequestsKeyHandling?

    override func keyDown(with event: NSEvent) {
        if keyHandler?.pullRequestsKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if keyHandler?.pullRequestsKeyDown(NSEvent.synthesizeEscape()) == true { return }
        super.cancelOperation(sender)
    }
}
