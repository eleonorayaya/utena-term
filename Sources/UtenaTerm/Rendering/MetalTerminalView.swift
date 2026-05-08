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

    // Direct PTY panes: the view's bounds are authoritative. setFrameSize
    // recomputes gridCols/gridRows and pushes them through bridge.resize +
    // pty.resize via onResize, so the shell sees a grid that matches what
    // we actually render.
    //
    // Tmux panes: tmux owns the layout. We get pane sizes via %layout-change
    // and the rendered pane bounds may not divide cleanly into that cell
    // count (per-pane padding + NSSplitView divider eat ~2 cols + a row).
    // If the view recomputes from bounds and overrides tmux's cols/rows,
    // the shell (whose SIGWINCH came from tmux) and our VT bridge disagree
    // by ~2 cols per pane and TUI apps wrap a column or two early. Setting
    // this to false makes setFrameSize / viewDidChangeBackingProperties
    // pass through cell-pixel metrics only, preserving the cols/rows the
    // owner cached via setOwnerGridSize.
    var viewDrivesGridSize: Bool = true
    private var ownerCols: UInt16 = 0
    private var ownerRows: UInt16 = 0

    /// Called by the owner (TmuxPane) whenever tmux hands it new pane
    /// dimensions. Caches them so subsequent frame / backing-scale changes
    /// can refresh cell-pixel metrics without trampling tmux's grid size.
    func setOwnerGridSize(cols: UInt16, rows: UInt16) {
        ownerCols = cols
        ownerRows = rows
    }

    override init(frame: NSRect, device: MTLDevice?) {
        font = CTFontCreateWithName("MesloLGS Nerd Font Mono" as CFString, 13, nil)
        super.init(frame: frame, device: device)
        computeCellMetrics()
        isPaused = true
        enableSetNeedsDisplay = true
        // 120fps cap (vs default 60) halves the worst-case wait between
        // setNeedsDisplay and the next eligible draw on a ProMotion display.
        // No effect on non-ProMotion panels; the on-demand draw model still
        // means we only render when bytes arrive.
        preferredFramesPerSecond = 120
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        if let metalLayer = layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            // Default is 3; dropping to 2 shaves one frame from the present
            // pipeline depth. Trade is sustained-throughput headroom under
            // heavy continuous output, which is fine for an interactive
            // terminal where echo latency dominates perceived quality.
            metalLayer.maximumDrawableCount = 2
        }
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

    /// Cell size in device pixels, snapped + clamped to ≥ 1. Required by
    /// every bridge.resize and PTY-resize path; centralized so the rounding
    /// rule stays consistent across resize callbacks.
    func cellPixelMetrics() -> (cw: UInt32, ch: UInt32) {
        let scale = backingScale
        let cwPx = UInt32(max(1, Int(round(cellWidth * scale))))
        let chPx = UInt32(max(1, Int(round(cellHeight * scale))))
        return (cwPx, chPx)
    }

    func makeSizeReport() -> GhosttySizeReportSize {
        let (cwPx, chPx) = cellPixelMetrics()
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
        let (cwPx, chPx) = cellPixelMetrics()
        let (cols, rows) = effectiveGridSize()
        if cols > 0 && rows > 0 {
            bridge?.resize(cols: cols, rows: rows, cellWidthPx: cwPx, cellHeightPx: chPx)
        }
        renderer?.invalidateGlyphState()
        setNeedsDisplay(bounds)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.resize(width: Int(newSize.width), height: Int(newSize.height))
        let (cwPx, chPx) = cellPixelMetrics()
        let (cols, rows) = effectiveGridSize()
        if cols > 0 && rows > 0 {
            bridge?.resize(cols: cols, rows: rows, cellWidthPx: cwPx, cellHeightPx: chPx)
        }
        let pxWInt: Int = max(1, Int(newSize.width * backingScale))
        let pxHInt: Int = max(1, Int(newSize.height * backingScale))
        let pxW = UInt16(min(Int(UInt16.max), pxWInt))
        let pxH = UInt16(min(Int(UInt16.max), pxHInt))
        // onResize is for direct-PTY panes that drive pty.resize from the
        // view's bounds. Tmux panes leave it nil (layout is tmux-driven).
        if viewDrivesGridSize {
            onResize?(gridCols, gridRows, pxW, pxH)
        }
        setNeedsDisplay(bounds)
    }

    /// View bounds when this pane owns its size; the owner's cached cols/rows
    /// otherwise. Returns (0, 0) only briefly during init for tmux panes
    /// before the first %layout-change arrives — callers must skip the
    /// bridge.resize in that case.
    private func effectiveGridSize() -> (cols: UInt16, rows: UInt16) {
        if viewDrivesGridSize {
            return (gridCols, gridRows)
        }
        return (ownerCols, ownerRows)
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
        Signpost.event("keyDown")
        // ⌘V → paste from system pasteboard. Without this, Cmd-V is forwarded
        // as a literal "v" press so apps inside the terminal never see paste.
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            paste(self)
            return
        }
        let key = KeyMap.ghosttyKey(for: event.keyCode)
        let mods = KeyMap.ghosttyMods(for: event.modifierFlags)
        let text = encoderText(for: event)
        if let bytes = bridge.encode(key: key, mods: mods, action: GHOSTTY_KEY_ACTION_PRESS, utf8text: text) {
            onInput?(bytes)
        }
    }

    /// Returns the utf8 text the ghostty encoder expects for this key event,
    /// or nil for cases the encoder must dispatch from key code alone:
    ///  - option-dead-keys (platform glyphs the encoder can't read)
    ///  - C0/DEL bytes (Ctrl+letter macOS pre-translates)
    ///  - macOS function-key PUA range 0xF700–0xF8FF
    /// Per ghostty/vt/key/event.h, the encoder wants the unmodified character.
    private func encoderText(for event: NSEvent) -> String? {
        guard !event.modifierFlags.contains(.option),
              let t = event.charactersIgnoringModifiers
        else { return nil }
        let unsafe = t.unicodeScalars.contains { v in
            let c = v.value
            return c < 0x0020 || c == 0x007F || (0xF700 ... 0xF8FF).contains(c)
        }
        return unsafe ? nil : t
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
