import AppKit
import Metal

final class TmuxPane {
    let paneID: String
    let bridge: GhosttyBridge
    let view: MetalTerminalView
    weak var controlSession: TmuxControlSession?

    init(paneID: String, cols: UInt16, rows: UInt16, controlSession: TmuxControlSession) {
        self.paneID = paneID
        self.controlSession = controlSession
        bridge = try! GhosttyBridge(cols: cols, rows: rows)
        let device = MTLCreateSystemDefaultDevice()!
        view = MetalTerminalView(frame: .zero, device: device)
        view.bridge = bridge
        // Tmux owns pane sizing — see comment on MetalTerminalView.viewDrivesGridSize.
        view.viewDrivesGridSize = false
        view.setOwnerGridSize(cols: cols, rows: rows)
        let renderer = TerminalRenderer(device: device, view: view)
        view.renderer = renderer
        view.delegate = renderer
        view.onInput = { [weak self] data in
            guard let self else { return }
            self.controlSession?.sendKeys(pane: self.paneID, data: data)
        }
        view.onFocus = { [weak self] in
            guard let self else { return }
            self.controlSession?.selectPane(target: self.paneID)
        }
    }

    func receive(_ data: Data) {
        Signpost.event("paneReceive", "pane=\(paneID) bytes=\(data.count)")
        bridge.write(data)
        view.needsDisplay = true
    }

    func resize(cols: UInt16, rows: UInt16) {
        view.setOwnerGridSize(cols: cols, rows: rows)
        // Carry cell-pixel metrics through so hi-DPI rendering stays sharp;
        // these are the same values setFrameSize would have used.
        let (cwPx, chPx) = view.cellPixelMetrics()
        bridge.resize(cols: cols, rows: rows, cellWidthPx: cwPx, cellHeightPx: chPx)
    }
}
