import Foundation
import ImageIO
import simd
import GhosttyVt

struct CursorState {
    var x: UInt16
    var y: UInt16
    var style: GhosttyRenderStateCursorVisualStyle
}

final class GhosttyBridge {
    private(set) var terminal: GhosttyTerminal
    private var renderState: GhosttyRenderState
    private var keyEncoder: GhosttyKeyEncoder
    private var keyEvent: GhosttyKeyEvent
    private(set) var colors: GhosttyRenderStateColors

    var sizeProvider: (() -> GhosttySizeReportSize)?
    var onPtyWrite: ((Data) -> Void)?

    private var codepointsScratch: [UInt32] = []

    init(cols: UInt16, rows: UInt16, maxScrollback: Int = 10_000) throws {
        let opts = GhosttyTerminalOptions(cols: cols, rows: rows, max_scrollback: maxScrollback)
        var term: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &term, opts) == GHOSTTY_SUCCESS, let term else {
            throw BridgeError.initFailed("terminal")
        }
        terminal = term

        var rs: GhosttyRenderState?
        guard ghostty_render_state_new(nil, &rs) == GHOSTTY_SUCCESS, let rs else {
            ghostty_terminal_free(term)
            throw BridgeError.initFailed("render_state")
        }
        renderState = rs

        var enc: GhosttyKeyEncoder?
        guard ghostty_key_encoder_new(nil, &enc) == GHOSTTY_SUCCESS, let enc else {
            ghostty_render_state_free(rs)
            ghostty_terminal_free(term)
            throw BridgeError.initFailed("key_encoder")
        }
        keyEncoder = enc

        var ev: GhosttyKeyEvent?
        guard ghostty_key_event_new(nil, &ev) == GHOSTTY_SUCCESS, let ev else {
            ghostty_key_encoder_free(enc)
            ghostty_render_state_free(rs)
            ghostty_terminal_free(term)
            throw BridgeError.initFailed("key_event")
        }
        keyEvent = ev

        // Enable Kitty graphics storage (335 MB)
        var kittyLimit: UInt64 = 335 * 1024 * 1024
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyLimit)

        // Register PNG decode callback (process-global, safe to call multiple times).
        // ghostty_sys_set uses the same @ptrCast convention as ghostty_terminal_set:
        // value IS the function pointer, not a pointer to it.
        let decodeFn: GhosttySysDecodePngFn = ghosttyDecodePng
        _ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, unsafeBitCast(decodeFn, to: UnsafeRawPointer?.self))

        var c = GhosttyRenderStateColors()
        c.size = MemoryLayout<GhosttyRenderStateColors>.size
        colors = c

        // Register XTWINOPS size query and pty-write callbacks.
        // ghostty_terminal_set takes the VALUE as void*, not a pointer to it —
        // the Zig side does @ptrCast(value) directly into the function pointer field.
        // For function callbacks: unsafeBitCast the fn ptr to UnsafeRawPointer?.
        // For userdata: pass the opaque pointer directly.
        let userdataPtr = Unmanaged.passUnretained(self).toOpaque()
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, userdataPtr)
        let sizeFn: GhosttyTerminalSizeFn = ghosttySizeCallback
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(sizeFn, to: UnsafeRawPointer?.self))
        let writeFn: GhosttyTerminalWritePtyFn = ghosttyWritePtyCallback
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writeFn, to: UnsafeRawPointer?.self))
    }

    deinit {
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_render_state_free(renderState)
        ghostty_terminal_free(terminal)
    }

    private var encoderNeedsSync = true

    func write(_ data: Data) {
        data.withUnsafeBytes { buf in
            guard let ptr = buf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            ghostty_terminal_vt_write(terminal, ptr, buf.count)
        }
        // Defer the encoder sync until the next encode() — keystrokes are
        // ~10000× rarer than pane writes, so syncing per write burns 3 FFI
        // calls for nothing on every chunk of pane output.
        encoderNeedsSync = true
    }

    /// Pull terminal-driven options into the encoder, then force kitty
    /// keyboard / modifyOtherKeys off. Without the override, once a TUI
    /// (e.g. Claude) enables progressive enhancement the encoder starts
    /// emitting plain "o" for ⌃o instead of 0x0F. We don't consume those
    /// protocols anywhere yet.
    private func syncEncoderFromTerminal() {
        ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
        var kittyFlags = GhosttyKittyKeyFlags(GHOSTTY_KITTY_KEY_DISABLED)
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS, &kittyFlags)
        var modifyOtherKeys2 = false
        ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2, &modifyOtherKeys2)
        encoderNeedsSync = false
    }

    func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32 = 0, cellHeightPx: UInt32 = 0) {
        _ = ghostty_terminal_resize(terminal, cols, rows, cellWidthPx, cellHeightPx)
        _ = ghostty_render_state_update(renderState, terminal)
    }

    @discardableResult
    func updateRenderState() -> Bool {
        _ = ghostty_render_state_update(renderState, terminal)

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)

        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_colors_get(renderState, &colors)

        return dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE
    }

    func clearDirty() {
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &dirty)
    }

    func withRowIterator(_ body: (GhosttyRenderStateRowIterator, GhosttyRenderStateRowCells) -> Void) {
        var iter: GhosttyRenderStateRowIterator?
        guard ghostty_render_state_row_iterator_new(nil, &iter) == GHOSTTY_SUCCESS, let iterHandle = iter else { return }
        defer { ghostty_render_state_row_iterator_free(iterHandle) }

        var cells: GhosttyRenderStateRowCells?
        guard ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS, let cellsHandle = cells else { return }
        defer { ghostty_render_state_row_cells_free(cellsHandle) }

        // Pass &iter (pointer to the optional handle) so C can populate the iterator's
        // internal row state — not the handle value, which would write to garbage memory.
        withUnsafeMutablePointer(to: &iter) { ptr in
            _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, UnsafeMutableRawPointer(ptr))
        }

        body(iterHandle, cellsHandle)
    }

    func snapshotViewport() -> ViewportSnapshot {
        _ = updateRenderState()
        var rows: [RowSnapshot] = []
        withRowIterator { iter, cellsHandle in
            var cells = cellsHandle
            while ghostty_render_state_row_iterator_next(iter) {
                withUnsafeMutablePointer(to: &cells) { cp in
                    _ = ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, UnsafeMutableRawPointer(cp))
                }
                rows.append(decodeRow(cells: cells))

                var clean = false
                ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
            }
        }
        return ViewportSnapshot(rows: rows, cursor: cursorState(), colors: colors)
    }

    private func decodeRow(cells: GhosttyRenderStateRowCells) -> RowSnapshot {
        let bg = colors.background
        var snapshotCells: [CellSnapshot] = []
        var rowText = ""
        while ghostty_render_state_row_cells_next(cells) {
            var graphemeLen: UInt32 = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen)
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

            // Reuse a hoisted scratch buffer rather than allocating per cell. The C call
            // writes graphemeLen UInt32s; we only read the first, but the buffer must be
            // large enough to receive the full grapheme cluster.
            let needed = max(1, Int(graphemeLen))
            if codepointsScratch.count < needed {
                codepointsScratch = [UInt32](repeating: 0, count: needed)
            }
            if graphemeLen > 0 {
                _ = codepointsScratch.withUnsafeMutableBufferPointer { buf in
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, UnsafeMutableRawPointer(buf.baseAddress!))
                }
            }

            let scalar: Unicode.Scalar
            if graphemeLen > 0, let s = Unicode.Scalar(codepointsScratch[0]) {
                scalar = s
            } else {
                scalar = Unicode.Scalar(0x20)!
            }
            rowText.unicodeScalars.append(scalar)

            let fg = resolveColor(style.fg_color, colors: colors, fallback: colors.foreground)
            let fgVec = SIMD4<Float>(Float(fg.r)/255, Float(fg.g)/255, Float(fg.b)/255, 1)

            let cellBg = resolveColor(style.bg_color, colors: colors, fallback: bg)
            let bgVec: SIMD4<Float>?
            if cellBg.r != bg.r || cellBg.g != bg.g || cellBg.b != bg.b {
                bgVec = SIMD4<Float>(Float(cellBg.r)/255, Float(cellBg.g)/255, Float(cellBg.b)/255, 1)
            } else {
                bgVec = nil
            }
            snapshotCells.append(CellSnapshot(scalar: scalar, fg: fgVec, bg: bgVec))
        }
        return RowSnapshot(cells: snapshotCells, rowText: rowText)
    }

    func cursorState() -> CursorState? {
        var visible: Bool = false
        var inViewport: Bool = false
        var x: UInt16 = 0
        var y: UInt16 = 0
        var style = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK

        guard ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible) == GHOSTTY_SUCCESS else { return nil }
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &inViewport)
        guard visible, inViewport else { return nil }
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        _ = ghostty_render_state_get(renderState, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &style)

        return CursorState(x: x, y: y, style: style)
    }

    func encode(
        key: GhosttyKey,
        mods: GhosttyMods,
        action: GhosttyKeyAction,
        utf8text: String?
    ) -> Data? {
        if encoderNeedsSync { syncEncoderFromTerminal() }
        ghostty_key_event_set_action(keyEvent, action)
        ghostty_key_event_set_key(keyEvent, key)
        ghostty_key_event_set_mods(keyEvent, mods)

        let bufferCapacity = 128
        var buf = [UInt8](repeating: 0, count: bufferCapacity)
        var written: Int = 0

        let result: GhosttyResult
        if let text = utf8text {
            result = text.withCString { ptr in
                ghostty_key_event_set_utf8(keyEvent, ptr, text.utf8.count)
                return buf.withUnsafeMutableBufferPointer { bufPtr in
                    let charPtr = bufPtr.baseAddress.map { UnsafeMutablePointer<CChar>(OpaquePointer($0)) }
                    return ghostty_key_encoder_encode(keyEncoder, keyEvent, charPtr, bufferCapacity, &written)
                }
            }
        } else {
            ghostty_key_event_set_utf8(keyEvent, nil, 0)
            result = buf.withUnsafeMutableBufferPointer { bufPtr in
                let charPtr = bufPtr.baseAddress.map { UnsafeMutablePointer<CChar>(OpaquePointer($0)) }
                return ghostty_key_encoder_encode(keyEncoder, keyEvent, charPtr, bufferCapacity, &written)
            }
        }

        guard result == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return Data(buf[..<written])
    }

    func scroll(delta: Int) {
        let value = GhosttyTerminalScrollViewportValue(delta: delta)
        let behavior = GhosttyTerminalScrollViewport(
            tag: GHOSTTY_SCROLL_VIEWPORT_DELTA,
            value: value
        )
        ghostty_terminal_scroll_viewport(terminal, behavior)
    }

    func withKittyGraphics(_ body: (GhosttyKittyGraphics, GhosttyTerminal) -> Void) {
        var handle: GhosttyKittyGraphics?
        guard ghostty_terminal_get(
            terminal,
            GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
            &handle
        ) == GHOSTTY_SUCCESS, let h = handle else { return }
        body(h, terminal)
    }

    enum BridgeError: Error {
        case initFailed(String)
    }
}

// MARK: - XTWINOPS size callback (C-compatible)

private func ghosttySizeCallback(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ outSize: UnsafeMutablePointer<GhosttySizeReportSize>?
) -> Bool {
    guard let userdata, let outSize else { return false }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    guard let size = bridge.sizeProvider?() else { return false }
    outSize.pointee = size
    return true
}

// MARK: - PTY write callback (C-compatible)

private func ghosttyWritePtyCallback(
    _ terminal: GhosttyTerminal?,
    _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?,
    _ len: Int
) {
    guard let userdata, let data, len > 0 else { return }
    let bridge = Unmanaged<GhosttyBridge>.fromOpaque(userdata).takeUnretainedValue()
    let buffer = UnsafeBufferPointer(start: data, count: len)
    bridge.onPtyWrite?(Data(buffer))
}

// MARK: - PNG decode callback (C-compatible, process-global)

private func ghosttyDecodePng(
    _ userdata: UnsafeMutableRawPointer?,
    _ allocator: UnsafePointer<GhosttyAllocator>?,
    _ data: UnsafePointer<UInt8>?,
    _ dataLen: Int,
    _ out: UnsafeMutablePointer<GhosttySysImage>?
) -> Bool {
    guard let data, let out else { return false }

    let cfData = CFDataCreateWithBytesNoCopy(nil, data, dataLen, kCFAllocatorNull)!
    guard let src = CGImageSourceCreateWithData(cfData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }

    let w = cgImage.width
    let h = cgImage.height
    let byteCount = w * h * 4
    guard let pixelBuf = ghostty_alloc(allocator, byteCount) else { return false }

    guard let ctx = CGContext(
        data: UnsafeMutableRawPointer(pixelBuf),
        width: w, height: h,
        bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        ghostty_free(allocator, pixelBuf, byteCount)
        return false
    }
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

    out.pointee.width = UInt32(w)
    out.pointee.height = UInt32(h)
    out.pointee.data = pixelBuf
    out.pointee.data_len = byteCount
    return true
}
