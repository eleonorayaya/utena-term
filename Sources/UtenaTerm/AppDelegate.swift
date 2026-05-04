import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: TerminalWindow!
    private var splitManager: SplitManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialCols: UInt16 = 80
        let initialRows: UInt16 = 24

        let initialPane = TerminalPane(cols: initialCols, rows: initialRows)
        initialPane.view.isActive = true
        splitManager = SplitManager(initialPane: initialPane)

        let cellW = initialPane.view.cellWidth
        let cellH = initialPane.view.cellHeight
        let contentSize = NSSize(width: cellW * Double(initialCols),
                                  height: cellH * Double(initialRows))

        window = TerminalWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal"
        window.contentView = initialPane.view
        window.splitDelegate = self
        window.makeFirstResponder(initialPane.view)
        window.center()
        window.makeKeyAndOrderFront(nil)

        splitManager.window = window
        splitManager.onLastPaneClosed = { [weak self] in
            self?.window.close()
        }

        let cols = initialPane.view.gridCols
        let rows = initialPane.view.gridRows
        initialPane.resize(cols: cols, rows: rows)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(ptyDidClose(_:)),
            name: .ptyDidClose,
            object: nil
        )
    }

    @objc private func ptyDidClose(_ note: Notification) {
        guard let pty = note.object as? PtyManager else { return }
        let leaves = splitManager.root.leaves()
        guard let pane = leaves.first(where: { $0.pty === pty }) else { return }
        splitManager.closePane(pane)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension AppDelegate: TerminalWindowDelegate {
    func terminalWindowSplitVertical() {
        splitManager.split(axis: .vertical)
    }

    func terminalWindowSplitHorizontal() {
        splitManager.split(axis: .horizontal)
    }

    func terminalWindowFocusNext() {
        splitManager.focusNext()
    }

    func terminalWindowFocusPrev() {
        splitManager.focusPrev()
    }

    func terminalWindowClosePane() {
        splitManager.closePane(splitManager.focusedPane)
    }
}
