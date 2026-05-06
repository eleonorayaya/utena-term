import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private var tmuxControllers: [TmuxWindowController] = []
    private var launcherControllers: [LauncherWindowController] = []
    private let notifier = AttentionNotifier()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await UtenaDaemonClient.shared.start() }
        notifier.start()
        // Open a launcher with the switcher auto-opened.
        openLauncher()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openLauncher(_ sender: Any? = nil) {
        let lc = LauncherWindowController()
        launcherControllers.append(lc)
        observeWindowClose(lc.window)
        lc.showWindow(nil)
    }

    @objc func openTmuxWindow(_ sender: Any?) {
        // ⌘⇧N now opens a new launcher (which auto-opens the switcher).
        openLauncher(sender)
    }

    func adoptTmuxController(_ controller: TmuxWindowController) {
        tmuxControllers.append(controller)
        observeWindowClose(controller.window)
    }

    private func observeWindowClose(_ win: NSWindow?) {
        guard let win else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: win
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        tmuxControllers.removeAll { $0.window === win }
        launcherControllers.removeAll { $0.window === win }
        controllers.removeAll { $0.window === win }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: win)
    }
}
