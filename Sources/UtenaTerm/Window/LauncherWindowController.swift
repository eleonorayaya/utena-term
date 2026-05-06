import AppKit

final class LauncherWindowController: NSWindowController {
    private var switcher: SwitcherController!

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

        let s = SwitcherController()
        s.delegate = self
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

extension LauncherWindowController: SwitcherDelegate {
    var currentSessionName: String { "" }

    func switcherAttach(tmuxName: String) {
        openTmuxAndClose(launch: .attach(tmuxName: tmuxName))
    }

    func switcherCreateSession() {
        // Close the switcher panel first; SessionPickerController is also a panel
        // and stacking two non-activating panels gets messy.
        switcher.close()
        let sessions = syncAwait { try await UtenaDaemonClient.shared.fetchOnce() } ?? []
        let result = SessionPickerController.run(sessions: sessions)
        switch result {
        case .cancel:
            // Re-open the switcher so the launcher remains usable.
            if let win = window { switcher.open(near: win) }
        case .attach(let s):
            guard let n = s.tmuxSession?.name else { return }
            openTmuxAndClose(launch: .attach(tmuxName: n))
        case .create(let name, let wsId, let branch):
            openTmuxAndClose(launch: .create(name: name, workspaceId: wsId, branch: branch))
        }
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

// Blocks the calling thread until an async throwing operation completes.
// Use only from synchronous main-thread init (mirrors NSAlert.runModal() behavior).
private func syncAwait<T>(_ work: @Sendable @escaping () async throws -> T) -> T? {
    var result: T?
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        result = try? await work()
        sem.signal()
    }
    sem.wait()
    return result
}
