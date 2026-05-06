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

        let panel = HelpPanel(contentRect: panelFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        // Add visual effect view for vibrant dark background
        let effectView = NSVisualEffectView(frame: panelFrame)
        effectView.material = .dark
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        panel.contentView = effectView

        // Add content view on top
        let containerView = NSView(frame: panelFrame)
        effectView.addSubview(containerView)

        contentView.frame = panelFrame
        containerView.addSubview(contentView)

        panel.keyHandler = self
        self.panel = panel
        isOpen = true

        // Position centered on parent window
        if let parent = parentWindow {
            let parentFrame = parent.frame
            let x = parentFrame.midX - width / 2
            let y = parentFrame.midY + height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }

        panel.makeKeyAndOrderFront(nil)
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
