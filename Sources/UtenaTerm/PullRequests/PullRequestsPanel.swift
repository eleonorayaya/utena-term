import AppKit

protocol PullRequestsKeyHandling: AnyObject {
    func pullRequestsKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel for pull requests — mirrors WorkspacesPanel.
final class PullRequestsPanel: NSPanel {
    weak var keyHandler: PullRequestsKeyHandling?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.pullRequestsKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if keyHandler?.pullRequestsKeyDown(NSEvent.escape()) == true { return }
        super.cancelOperation(sender)
    }
}

private extension NSEvent {
    static func escape() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 0x35
        )!
    }
}
