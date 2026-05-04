import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var pane: TerminalPane!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let initialCols: UInt16 = 80
        let initialRows: UInt16 = 24

        pane = TerminalPane(cols: initialCols, rows: initialRows)

        let cellW = pane.view.cellWidth
        let cellH = pane.view.cellHeight
        let contentSize = NSSize(width: cellW * Double(initialCols),
                                  height: cellH * Double(initialRows))

        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Terminal"
        window.contentView = pane.view
        window.makeFirstResponder(pane.view)
        window.center()
        window.makeKeyAndOrderFront(nil)

        let cols = pane.view.gridCols
        let rows = pane.view.gridRows
        pane.resize(cols: cols, rows: rows)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
