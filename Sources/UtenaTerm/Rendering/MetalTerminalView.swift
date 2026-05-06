import AppKit
import MetalKit
import GhosttyVt

final class MetalTerminalView: MTKView {
    var bridge: GhosttyBridge!
    var onInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16, UInt16, UInt16) -> Void)?
    var onFocus: (() -> Void)?
    var isActive: Bool = false { didSet { setNeedsDisplay(bounds) } }
    var backgroundAppearance: PaneAppearance? = nil { didSet { setNeedsDisplay(bounds) } }
    var resolvedBackground: PaneAppearance {
        backgroundAppearance ?? (window as? TerminalWindow)?.windowBackground ?? .default
    }

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
        (layer as? CAMetalLayer)?.isOpaque = false
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        computeCellMetrics()
        let scale = backingScale
        let cwPx = UInt32(max(1, Int(round(cellWidth * scale))))
        let chPx = UInt32(max(1, Int(round(cellHeight * scale))))
        bridge?.resize(cols: gridCols, rows: gridRows, cellWidthPx: cwPx, cellHeightPx: chPx)
        renderer?.invalidateGlyphState()
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
        // ⌘V → paste from system pasteboard. Without this, Cmd-V is forwarded
        // as a literal "v" press so apps inside the terminal never see paste.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            paste(self)
            return
        }
        let key = KeyMap.ghosttyKey(for: event.keyCode)
        let mods = KeyMap.ghosttyMods(for: event.modifierFlags)

        // Prefer charactersIgnoringModifiers as the encoder's utf8 text.
        // event.characters has macOS pre-translate Ctrl+letter to the matching
        // ASCII control char (Ctrl+O → "\u{0F}") and option-dead-keys to glyphs
        // the encoder doesn't recognize. Niling out text in those cases left
        // ghostty with only the key code, which made it return zero bytes for
        // legacy Ctrl chords — Ctrl+O never made it onto the wire. Function
        // keys come back as 0xF700–0xF8FF private-use codepoints; null those
        // out so the encoder falls back to key-code dispatch.
        var text: String? = event.charactersIgnoringModifiers
        if event.modifierFlags.contains(.option) {
            text = nil
        }
        if let t = text {
            let unsafe = t.unicodeScalars.contains { v in
                let c = v.value
                return c < 0x0020 || c == 0x007F || (c >= 0xF700 && c <= 0xF8FF)
            }
            if unsafe { text = nil }
        }

        let bytes = bridge.encode(key: key, mods: mods, action: GHOSTTY_KEY_ACTION_PRESS, utf8text: text)
        if ProcessInfo.processInfo.environment["UTENA_KEY_LOG"] != nil {
            let hex = bytes.map { $0.map { String(format: "%02x", $0) }.joined(separator: " ") } ?? "(nil)"
            FileHandle.standardError.write(Data("[key↓] code=\(event.keyCode) mods=\(mods) text=\(text ?? "nil") → bytes=\(hex)\n".utf8))
        }
        if let bytes { onInput?(bytes) }
    }

    @objc func paste(_ sender: Any?) {
        guard let s = NSPasteboard.general.string(forType: .string), !s.isEmpty else { return }
        // Bracketed-paste mode (DEC 2004) — apps that opt in via `ESC[?2004h`
        // get a wrapped chunk so they can detect pasted vs typed input. The VT
        // parser handles enable/disable; we always send the wrapper bytes and
        // it's a no-op if bracketed-paste isn't active.
        let begin: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC[200~
        let end:   [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]   // ESC[201~
        var data = Data()
        data.append(contentsOf: begin)
        data.append(contentsOf: Array(s.utf8))
        data.append(contentsOf: end)
        onInput?(data)
    }

    private var scrollAccumY: CGFloat = 0
    override func scrollWheel(with event: NSEvent) {
        scrollAccumY += event.scrollingDeltaY
        let deltaRows = Int(scrollAccumY / cellHeight)
        if deltaRows != 0 {
            scrollAccumY -= CGFloat(deltaRows) * cellHeight
            bridge.scroll(delta: deltaRows)
            setNeedsDisplay(bounds)
        }
    }
}
