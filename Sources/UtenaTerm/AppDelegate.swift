import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [TerminalWindowController] = []
    private var tmuxControllers: [TmuxWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TerminalWindowController()
        controllers.append(controller)
        controller.showWindow(nil)

        Task {
            await UtenaDaemonClient.shared.start()
            for await sessions in UtenaDaemonClient.shared.sessions {
                let summary = sessions.map { s in
                    "\(s.name) [\(s.status.rawValue)]\(s.needsAttention ? " ⚠️" : "")"
                }
                print("[utena] sessions: \(summary)")
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc func openTmuxWindow(_ sender: Any?) {
        let controller = TmuxWindowController()
        guard controller.isReady, let win = controller.window else { return }
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
