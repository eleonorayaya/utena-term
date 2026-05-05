import AppKit
import MetalKit
import GhosttyVt

final class MetalTerminalView: MTKView {
    var bridge: GhosttyBridge!
    var onInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16, UInt16, UInt16) -> Void)?
    var onFocus: (() -> Void)?
    var isActive: Bool = false { didSet { setNeedsDisplay(bounds) } }

    let font: CTFont
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    var cellAscent: CGFloat = 0
    var renderer: TerminalRenderer?
    let padX: CGFloat = 8
    let padY: CGFloat = 6

    override init(frame: NSRect, device: MTLDevice?) {
        font = CTFontCreateWithName("MesloLGS Nerd Font Mono" as CFString, 13, nil)
        super.init(frame: frame, device: device)
        computeCellMetrics()
        isPaused = true
        enableSetNeedsDisplay = true
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    required init(coder: NSCoder) { fatalError() }

    private func computeCellMetrics() {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellAscent = ascent
        var glyph: CGGlyph = 0
        var ch: UniChar = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        // Snap to whole device pixels so glyph quads land on integer boundaries,
        // preventing the linear sampler from blurring across sub-pixel offsets.
        let scale = backingScale
        cellWidth = max(1, (advance.width * scale).rounded()) / scale
        cellHeight = max(1, ((ascent + descent + leading) * scale).rounded()) / scale
    }

    var gridCols: UInt16 { UInt16(max(1, Int((bounds.width - 2 * padX) / cellWidth))) }
    var gridRows: UInt16 { UInt16(max(1, Int((bounds.height - 2 * padY) / cellHeight))) }

    var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
    }

    func makeSizeReport() -> GhosttySizeReportSize {
        let scale = backingScale
        let cwPx = UInt32(max(1, Int(round(cellWidth * scale))))
        let chPx = UInt32(max(1, Int(round(cellHeight * scale))))
        return GhosttySizeReportSize(
            rows: gridRows,
            columns: gridCols,
            cell_width: cwPx,
            cell_height: chPx
        )
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setNeedsDisplay(bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.resize(width: Int(newSize.width), height: Int(newSize.height))
        let scale = backingScale
        let cwPx = UInt32(max(1, Int(round(cellWidth * scale))))
        let chPx = UInt32(max(1, Int(round(cellHeight * scale))))
        bridge?.resize(cols: gridCols, rows: gridRows, cellWidthPx: cwPx, cellHeightPx: chPx)
        let pxWInt: Int = max(1, Int(newSize.width * backingScale))
        let pxHInt: Int = max(1, Int(newSize.height * backingScale))
        let pxW = UInt16(min(Int(UInt16.max), pxWInt))
        let pxH = UInt16(min(Int(UInt16.max), pxHInt))
        onResize?(gridCols, gridRows, pxW, pxH)
        setNeedsDisplay(bounds)
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { onFocus?() }
        return r
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let key = KeyMap.ghosttyKey(for: event.keyCode)
        let mods = KeyMap.ghosttyMods(for: event.modifierFlags)
        var text: String? = event.characters
        if event.modifierFlags.contains(.option) {
            text = nil
        } else if let t = text {
            let allPrintable = t.unicodeScalars.allSatisfy { v in
                let c = v.value
                return c > 0x001F && c != 0x007F && !(c >= 0xF700 && c <= 0xF8FF)
            }
            if !allPrintable { text = nil }
        }
        if let bytes = bridge.encode(key: key, mods: mods, action: GHOSTTY_KEY_ACTION_PRESS, utf8text: text) {
            onInput?(bytes)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaRows = Int(event.scrollingDeltaY / cellHeight)
        if deltaRows != 0 {
            bridge.scroll(delta: deltaRows)
            setNeedsDisplay(bounds)
        }
    }
}
