import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var terminalView: TerminalView!
    private var bridge: GhosttyBridge!
    private var pty: PtyManager!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialCols: UInt16 = 80
        let initialRows: UInt16 = 24

        bridge = try! GhosttyBridge(cols: initialCols, rows: initialRows)

        terminalView = TerminalView(frame: .zero)
        terminalView.bridge = bridge

        pty = PtyManager()
        pty.onData = { [weak self] data in
            guard let self else { return }
            self.bridge.write(data)
            self.terminalView.needsDisplay = true
        }
        terminalView.pty = pty
        pty.start(cols: initialCols, rows: initialRows)

        let cellW = terminalView.cellWidth
        let cellH = terminalView.cellHeight
        let contentSize = NSSize(width: cellW * Double(initialCols),
                                  height: cellH * Double(initialRows))

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal"
        window.contentView = terminalView
        window.makeFirstResponder(terminalView)
        window.center()
        window.makeKeyAndOrderFront(nil)

        let cols = terminalView.gridCols
        let rows = terminalView.gridRows
        bridge.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
