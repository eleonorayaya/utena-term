import AppKit

/// Base class for floating, non-activating overlay panels used across the app.
/// Provides standardized appearance (vibrant dark HUD background, rounded corners, shadow)
/// and key event routing through a handler protocol.
open class OverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }

    /// Initialize a standard overlay panel with the given size.
    public convenience init(size: NSSize) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay()
    }

    /// Initialize a standard overlay panel with explicit frame.
    public convenience init(contentRect: NSRect) {
        self.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        configureAsOverlay()
    }

    private func configureAsOverlay() {
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .modalPanel
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
    }

    /// Create and install a vibrant visual effect view and root content view with standard styling.
    /// Returns a tuple of (rootView, blurView) so subclasses can wire up content.
    public func installStandardVisualization() -> (rootView: OverlayRootView, blurView: NSVisualEffectView) {
        let root = OverlayRootView()
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView = root

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 20
        blur.layer?.masksToBounds = true
        root.addSubview(blur)

        return (root, blur)
    }
}

/// Standard root view for overlay panels: supports vibrant blurring,
/// applies corner radius mask, and draws a subtle border.
public final class OverlayRootView: NSView {
    public override var wantsDefaultClipping: Bool { true }

    public override func updateLayer() {
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Palette.border.cgColor
    }

    public override var allowsVibrancy: Bool { false }
}

/// Helper to synthesize an escape key event for consistent routing through keyDown handlers.
public extension NSEvent {
    static func synthesizeEscape() -> NSEvent {
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

/// Helper to center and show an overlay panel near a parent window.
public func centerPanel(_ panel: NSWindow, near parent: NSWindow?) {
    if let parent = parent {
        let parentFrame = parent.frame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: parentFrame.midX - panelSize.width / 2,
            y: parentFrame.midY - panelSize.height / 2
        )
        panel.setFrameOrigin(origin)
    } else {
        panel.center()
    }
    panel.makeKeyAndOrderFront(nil)
}
