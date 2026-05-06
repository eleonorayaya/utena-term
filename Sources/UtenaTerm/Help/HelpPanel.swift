import AppKit

protocol HelpKeyHandling: AnyObject {
    func helpKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel — keeps the terminal as the key window
/// underneath while the help is showing. Similar to SwitcherPanel.
final class HelpPanel: NSPanel {
    weak var keyHandler: HelpKeyHandling?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.helpKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ — let the controller decide whether to dismiss.
        if keyHandler?.helpKeyDown(NSEvent.escape()) == true { return }
        super.cancelOperation(sender)
    }
}

private extension NSEvent {
    /// Synthesize an esc keyDown so cancelOperation can route through the
    /// same handler as a real key press.
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
