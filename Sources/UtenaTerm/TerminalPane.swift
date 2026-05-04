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
        let initPxW = UInt16(max(1, Int(view.cellWidth * CGFloat(cols))))
        let initPxH = UInt16(max(1, Int(view.cellHeight * CGFloat(rows))))
        pty.start(cols: cols, rows: rows, pixelWidth: initPxW, pixelHeight: initPxH)
    }

    func resize(cols: UInt16, rows: UInt16) {
        bridge.resize(cols: cols, rows: rows)
        let pw = UInt16(max(1, Int(view.cellWidth * CGFloat(cols))))
        let ph = UInt16(max(1, Int(view.cellHeight * CGFloat(rows))))
        pty.resize(cols: cols, rows: rows, pixelWidth: pw, pixelHeight: ph)
    }
}
