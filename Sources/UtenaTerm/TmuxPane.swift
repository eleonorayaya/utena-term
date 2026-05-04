import AppKit

final class TmuxPane {
    let paneID: String
    let bridge: GhosttyBridge
    let view: TerminalView
    weak var controlSession: TmuxControlSession?

    init(paneID: String, cols: UInt16, rows: UInt16, controlSession: TmuxControlSession) {
        self.paneID = paneID
        self.controlSession = controlSession
        bridge = try! GhosttyBridge(cols: cols, rows: rows)
        view = TerminalView(frame: .zero)
        view.bridge = bridge
        view.onInput = { [weak self] data in
            guard let self else { return }
            self.controlSession?.sendKeys(pane: self.paneID, data: data)
        }
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.controlSession?.selectPane(target: self.paneID)
        }
        // onResize: bridge.resize is already called by TerminalView.setFrameSize;
        // tmux pane layout comes from %layout-change, not from view frame changes.
    }

    func receive(_ data: Data) {
        bridge.write(data)
        view.needsDisplay = true
    }

    func resize(cols: UInt16, rows: UInt16) {
        bridge.resize(cols: cols, rows: rows)
    }
}
