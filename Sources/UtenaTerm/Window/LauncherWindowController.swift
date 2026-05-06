import AppKit

final class LauncherWindowController: NSWindowController {
    private var switcher: SwitcherController!
    private var newSessionPicker: NewSessionPanelController?

    convenience init() {
        let win = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 550),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "utena-term"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.backgroundColor = Palette.surfaceBackground
        // Full-bleed: hide traffic lights. ⌘W in the switcher / new-session
        // picker bubbles to close the launcher (see SwitcherController +
        // NewSessionPanelController), so the user always has a way out.
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(kind)?.isHidden = true
        }

        // Empty content view with just palette background.
        let empty = NSView(frame: win.contentRect(forFrameRect: win.frame))
        empty.wantsLayer = true
        empty.layer?.backgroundColor = Palette.surfaceBackground.cgColor
        win.contentView = empty
        win.center()

        self.init(window: win)
        win.delegate = self

        let s = SwitcherController()
        s.delegate = self
        s.onClose = { [weak self] in
            // The launcher is just a host for the switcher — when the user
            // dismisses the switcher (Esc in normal mode), the launcher has
            // no purpose, so close it too. Defer to next tick so we don't
            // tear down the panel during its own keyDown unwind.
            DispatchQueue.main.async { self?.close() }
        }
        self.switcher = s
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Auto-open the switcher once the window is on screen
        DispatchQueue.main.async { [weak self] in
            guard let self, let win = self.window else { return }
            self.switcher.open(near: win)
        }
    }
}

extension LauncherWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // Window is going away — hide the floating switcher panel so it
        // doesn't orphan. Detach onClose first to avoid the panel re-closing
        // us mid-teardown.
        switcher?.onClose = nil
        switcher?.close()
    }
}

extension LauncherWindowController: SwitcherDelegate {
    var currentSessionName: String { "" }

    func switcherAttach(tmuxName: String) {
        openTmuxAndClose(launch: .attach(tmuxName: tmuxName))
    }

    func switcherCreateSession() {
        // Detach onClose first — closing the switcher would otherwise close
        // the launcher via the cascade, killing the new-session picker we're
        // about to open inside it.
        let savedOnClose = switcher.onClose
        switcher.onClose = nil
        switcher.close()

        let picker = NewSessionPanelController()
        picker.onComplete = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancel:
                // Re-arm the cascade and reopen the switcher.
                self.switcher.onClose = savedOnClose
                if let win = self.window { self.switcher.open(near: win) }
            case .attach(let s):
                guard let n = s.tmuxSession?.name else { return }
                self.openTmuxAndClose(launch: .attach(tmuxName: n))
            case .create(let input):
                self.openTmuxAndClose(launch: .create(input))
            }
            self.newSessionPicker = nil   // release the picker once it's settled
        }
        self.newSessionPicker = picker
        if let win = window { picker.open(near: win) }
    }

    func switcherDeleteSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.deleteSession(id: id) }
    }

    func switcherRepairSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.repairSession(id: id) }
    }

    func switcherArchiveSession(id: UInt) {
        Task { try? await UtenaDaemonClient.shared.archiveSession(id: id) }
    }

    private func openTmuxAndClose(launch: TmuxLaunch) {
        guard let app = NSApp.delegate as? AppDelegate else { return }
        if let controller = TmuxWindowController(launch: launch) {
            app.adoptTmuxController(controller)
            controller.showWindow(nil)
        }
        // Close the launcher window (and itself) on next tick to avoid
        // closing the parent of a dismissed panel mid-event.
        DispatchQueue.main.async { [weak self] in self?.close() }
    }
}
