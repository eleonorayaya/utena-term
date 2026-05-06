import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private var tmuxControllers: [TmuxWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await UtenaDaemonClient.shared.start() }
        // Default first window is tmux-backed (with the session picker) so
        // attach/create works on launch, mirroring ⌘⇧N. Picker cancel
        // falls back to a plain terminal inside openTmuxWindow.
        openTmuxWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openTmuxWindow(_ sender: Any?) {
        let controller = TmuxWindowController()
        guard let win = controller.window else { return }
        if !controller.isReady {
            // Picker was cancelled — open a plain terminal instead
            let plain = TerminalWindowController()
            controllers.append(plain)
            plain.showWindow(nil)
            return
        }
        tmuxControllers.append(controller)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(tmuxWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: win
        )
        controller.showWindow(nil)
    }

    @objc private func tmuxWindowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        tmuxControllers.removeAll { $0.window === win }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: win)
    }
}
