import AppKit

final class TerminalWindowController: NSWindowController {
    private var splitManager: SplitManager!

    convenience init() {
        let initialCols: UInt16 = 80
        let initialRows: UInt16 = 24

        let initialPane = TerminalPane(cols: initialCols, rows: initialRows)
        initialPane.view.isActive = true

        let cellW = initialPane.view.cellWidth
        let cellH = initialPane.view.cellHeight
        let contentSize = NSSize(width: cellW * Double(initialCols),
                                 height: cellH * Double(initialRows))

        let win = TerminalWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = "Terminal"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        win.contentView = initialPane.view
        win.makeFirstResponder(initialPane.view)
        win.center()
        win.backgroundColor = Palette.surfaceBackground
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(kind)?.isHidden = true
        }

        self.init(window: win)

        let sm = SplitManager(initialPane: initialPane)
        sm.window = win
        sm.onLastPaneClosed = { [weak self] in self?.window?.close() }
        splitManager = sm

        win.splitDelegate = self

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

    deinit {
        NotificationCenter.default.removeObserver(self, name: .ptyDidClose, object: nil)
    }
}

extension TerminalWindowController: TerminalWindowDelegate {
    func terminalWindowSplitVertical()   { splitManager.split(axis: .vertical) }
    func terminalWindowSplitHorizontal() { splitManager.split(axis: .horizontal) }
    func terminalWindowFocusNext()       { splitManager.focusNext() }
    func terminalWindowFocusPrev()       { splitManager.focusPrev() }
    func terminalWindowClosePane()       { splitManager.closePane(splitManager.focusedPane) }
    func terminalWindowToggleSwitcher()  { /* Switcher is tmux-only — no-op for plain terminal windows. */ }
    func terminalWindowNewWindow()       { /* tmux-only. */ }
    func terminalWindowSelectWindow(index: Int) { /* tmux-only. */ }
    func terminalWindowNextWindow()      { /* tmux-only. */ }
}
