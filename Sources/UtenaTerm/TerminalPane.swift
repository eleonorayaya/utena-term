import AppKit
import Metal
import GhosttyVt

final class TerminalPane {
    let bridge: GhosttyBridge
    let pty: PtyManager
    let view: MetalTerminalView

    init(cols: UInt16, rows: UInt16) {
        bridge = try! GhosttyBridge(cols: cols, rows: rows)
        let device = MTLCreateSystemDefaultDevice()!
        view = MetalTerminalView(frame: .zero, device: device)
        view.bridge = bridge
        let renderer = TerminalRenderer(device: device, view: view)
        view.renderer = renderer
        view.delegate = renderer
        bridge.sizeProvider = { [weak view] in
            view?.makeSizeReport() ?? GhosttySizeReportSize(rows: 0, columns: 0, cell_width: 0, cell_height: 0)
        }
        pty = PtyManager()
        bridge.onPtyWrite = { [weak self] data in
            // Defer to avoid calling pty.write() inside bridge.write()'s withUnsafeBytes
            DispatchQueue.main.async { [weak self] in self?.pty.write(data) }
        }
        pty.onData = { [weak self] data in
            guard let self else { return }
            self.bridge.write(data)
            self.view.setNeedsDisplay(self.view.bounds)
        }
        view.onInput = { [weak self] data in self?.pty.write(data) }
        view.onResize = { [weak self] cols, rows, pw, ph in self?.pty.resize(cols: cols, rows: rows, pixelWidth: pw, pixelHeight: ph) }
        let initScale = view.backingScale
        let initCwPx: Int = Int(round(view.cellWidth * initScale))
        let initChPx: Int = Int(round(view.cellHeight * initScale))
        let initPxW = UInt16(min(Int(UInt16.max), max(1, initCwPx * Int(cols))))
        let initPxH = UInt16(min(Int(UInt16.max), max(1, initChPx * Int(rows))))
        pty.start(cols: cols, rows: rows, pixelWidth: initPxW, pixelHeight: initPxH)
    }

    func resize(cols: UInt16, rows: UInt16) {
        let scale = view.backingScale
        let cwPx = UInt32(max(1, Int(round(view.cellWidth * scale))))
        let chPx = UInt32(max(1, Int(round(view.cellHeight * scale))))
        bridge.resize(cols: cols, rows: rows, cellWidthPx: cwPx, cellHeightPx: chPx)
        let cwPxInt: Int = Int(cwPx)
        let chPxInt: Int = Int(chPx)
        let pw = UInt16(min(Int(UInt16.max), max(1, cwPxInt * Int(cols))))
        let ph = UInt16(min(Int(UInt16.max), max(1, chPxInt * Int(rows))))
        pty.resize(cols: cols, rows: rows, pixelWidth: pw, pixelHeight: ph)
    }
}
