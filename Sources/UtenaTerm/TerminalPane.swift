import AppKit

final class TerminalPane {
    let bridge: GhosttyBridge
    let pty: PtyManager
    let view: TerminalView

    init(cols: UInt16, rows: UInt16) {
        bridge = try! GhosttyBridge(cols: cols, rows: rows)
        view = TerminalView(frame: .zero)
        view.bridge = bridge
        pty = PtyManager()
        pty.onData = { [weak self] data in
            guard let self else { return }
            self.bridge.write(data)
            self.view.needsDisplay = true
        }
        view.onInput = { [weak self] data in self?.pty.write(data) }
        view.onResize = { [weak self] cols, rows in self?.pty.resize(cols: cols, rows: rows) }
        pty.start(cols: cols, rows: rows)
    }

    func resize(cols: UInt16, rows: UInt16) {
        bridge.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
    }
}
