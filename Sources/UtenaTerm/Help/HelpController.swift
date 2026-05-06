import AppKit

/// Controls the help overlay panel — manages display, key handling, and lifecycle.
final class HelpController: NSObject, HelpKeyHandling {
    private(set) var isOpen = false
    private var panel: HelpPanel?

    /// Open the help overlay centered near the parent window.
    func open(near parentWindow: NSWindow?) {
        guard !isOpen else { return }

        let contentView = HelpContentView()
        let height = contentView.computedHeight()
        let width: CGFloat = 480
        let panelFrame = NSRect(x: 0, y: 0, width: width, height: height)

        let panel = HelpPanel(contentRect: panelFrame)
        let (root, _) = panel.installStandardVisualization()

        // Add content view on top of the blur
        contentView.frame = panelFrame
        root.addSubview(contentView)

        panel.keyHandler = self
        self.panel = panel
        isOpen = true

        // Position centered on parent window and make key
        centerPanel(panel, near: parentWindow)
    }

    /// Close the help overlay.
    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
        panel = nil
        isOpen = false
    }

    // MARK: - HelpKeyHandling

    func helpKeyDown(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let keyCode = event.keyCode

        // Close only on these specific keys:
        switch keyCode {
        case 0x35:  // ⎋ escape
            close()
            return true
        default:
            break
        }

        // Also close on ? (toggle), q, and ⌘w
        switch chars {
        case "?":
            close()
            return true
        case "q", "Q":
            close()
            return true
        default:
            break
        }

        // ⌘w (cmd-w)
        if event.modifierFlags.contains(.command) && chars == "w" {
            close()
            return true
        }

        // All other keys are eaten (no-op)
        return true
    }
}
