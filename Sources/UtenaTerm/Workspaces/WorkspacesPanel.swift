import AppKit

protocol WorkspacesKeyHandling: AnyObject {
    func workspacesKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel — mirrors SwitcherPanel.
final class WorkspacesPanel: NSPanel {
    weak var keyHandler: WorkspacesKeyHandling?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.workspacesKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if keyHandler?.workspacesKeyDown(NSEvent.escape()) == true { return }
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
