import AppKit

protocol SwitcherKeyHandling: AnyObject {
    func switcherKeyDown(_ event: NSEvent) -> Bool
}

/// Floating, non-activating panel — keeps the terminal as the key window
/// underneath while the switcher is showing. We override `canBecomeKey`
/// to true so that we still receive keyDown / firstResponder events.
final class SwitcherPanel: NSPanel {
    weak var keyHandler: SwitcherKeyHandling?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyHandler?.switcherKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // ⎋ — let the controller decide whether to dismiss.
        if keyHandler?.switcherKeyDown(NSEvent.escape()) == true { return }
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
