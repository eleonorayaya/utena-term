import AppKit
import CoreText
import GhosttyVt

final class TerminalView: NSView {
    var bridge: GhosttyBridge!
    var pty: PtyManager!

    private var font: CTFont
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private var cellAscent: CGFloat = 0

    override init(frame: NSRect) {
        font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        super.init(frame: frame)
        computeCellMetrics()
    }

    required init?(coder: NSCoder) {
        font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
        super.init(coder: coder)
        computeCellMetrics()
    }

    private func computeCellMetrics() {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        cellAscent = ascent
        cellHeight = ascent + descent + leading

        var glyph: CGGlyph = 0
        var ch: UniChar = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        cellWidth = advance.width
    }

    var gridCols: UInt16 {
        UInt16(max(1, Int(bounds.width / cellWidth)))
    }

    var gridRows: UInt16 {
        UInt16(max(1, Int(bounds.height / cellHeight)))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        bridge?.resize(cols: gridCols, rows: gridRows)
        pty?.resize(cols: gridCols, rows: gridRows)
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        bridge.updateRenderState()

        let colors = bridge.colors
        let bg = colors.background
        ctx.setFillColor(red: CGFloat(bg.r) / 255,
                         green: CGFloat(bg.g) / 255,
                         blue: CGFloat(bg.b) / 255,
                         alpha: 1)
        ctx.fill(bounds)

        bridge.withRowIterator { iter, cellsHandle in
            var cells = cellsHandle
            var rowIndex = 0
            while ghostty_render_state_row_iterator_next(iter) {
                withUnsafeMutablePointer(to: &cells) { cellsPtr in
                    _ = ghostty_render_state_row_get(
                        iter,
                        GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                        UnsafeMutableRawPointer(cellsPtr)
                    )
                }

                let rowY = bounds.height - CGFloat(rowIndex + 1) * cellHeight

                var colIndex = 0
                while ghostty_render_state_row_cells_next(cells) {
                    defer { colIndex += 1 }

                    var graphemeLen: UInt32 = 0
                    ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                        &graphemeLen
                    )

                    var style = GhosttyStyle()
                    style.size = MemoryLayout<GhosttyStyle>.size
                    ghostty_render_state_row_cells_get(
                        cells,
                        GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                        &style
                    )

                    let cellX = CGFloat(colIndex) * cellWidth

                    let cellBg = resolveColor(style.bg_color, colors: colors, fallback: bg)
                    if cellBg.r != bg.r || cellBg.g != bg.g || cellBg.b != bg.b {
                        ctx.setFillColor(
                            red: CGFloat(cellBg.r) / 255,
                            green: CGFloat(cellBg.g) / 255,
                            blue: CGFloat(cellBg.b) / 255,
                            alpha: 1
                        )
                        ctx.fill(CGRect(x: cellX, y: rowY, width: cellWidth, height: cellHeight))
                    }

                    if graphemeLen > 0 {
                        var codepoints = [UInt32](repeating: 0, count: Int(graphemeLen))
                        _ = codepoints.withUnsafeMutableBufferPointer { buf in
                            ghostty_render_state_row_cells_get(
                                cells,
                                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                                UnsafeMutableRawPointer(buf.baseAddress!)
                            )
                        }

                        let fg = resolveColor(style.fg_color, colors: colors, fallback: colors.foreground)
                        let fgCG = CGColor(
                            red: CGFloat(fg.r) / 255,
                            green: CGFloat(fg.g) / 255,
                            blue: CGFloat(fg.b) / 255,
                            alpha: 1
                        )

                        let chars = codepoints.prefix(Int(graphemeLen))
                            .compactMap { UnicodeScalar($0).map { Character($0) } }
                        if !chars.isEmpty {
                            let attrs: [CFString: Any] = [
                                kCTFontAttributeName: font,
                                kCTForegroundColorAttributeName: fgCG,
                            ]
                            let attrStr = CFAttributedStringCreate(
                                nil,
                                String(chars) as CFString,
                                attrs as CFDictionary
                            )!
                            let line = CTLineCreateWithAttributedString(attrStr)
                            ctx.textPosition = CGPoint(x: cellX, y: rowY + CTFontGetDescent(font))
                            CTLineDraw(line, ctx)
                        }
                    }
                }

                var clean = false
                ghostty_render_state_row_set(
                    iter,
                    GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                    &clean
                )

                rowIndex += 1
            }
        }

        if let cursor = bridge.cursorState() {
            let cx = CGFloat(cursor.x) * cellWidth
            let cy = bounds.height - CGFloat(cursor.y + 1) * cellHeight
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.8)
            ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.8)

            switch cursor.style {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                ctx.fill(CGRect(x: cx, y: cy, width: cellWidth, height: cellHeight))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW:
                ctx.stroke(CGRect(x: cx + 0.5, y: cy + 0.5, width: cellWidth - 1, height: cellHeight - 1))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                ctx.fill(CGRect(x: cx, y: cy, width: 2, height: cellHeight))
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                ctx.fill(CGRect(x: cx, y: cy, width: cellWidth, height: 2))
            default:
                ctx.fill(CGRect(x: cx, y: cy, width: cellWidth, height: cellHeight))
            }
        }

        bridge.clearDirty()
    }

    override func keyDown(with event: NSEvent) {
        let key = KeyMap.ghosttyKey(for: event.keyCode)
        let mods = KeyMap.ghosttyMods(for: event.modifierFlags)

        var text: String? = event.characters
        // Clear text when option is held — encoder handles alt-escape prefix
        if event.modifierFlags.contains(.option) {
            text = nil
        } else if let t = text {
            // Filter out C0 controls, DEL, and macOS PUA
            let allPrintable = t.unicodeScalars.allSatisfy { v in
                let c = v.value
                return c > 0x001F && c != 0x007F && !(c >= 0xF700 && c <= 0xF8FF)
            }
            if !allPrintable { text = nil }
        }
        let utf8text = text

        if let bytes = bridge.encode(key: key, mods: mods, action: GHOSTTY_KEY_ACTION_PRESS, utf8text: utf8text) {
            pty.write(bytes)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let deltaRows = Int(event.scrollingDeltaY / cellHeight)
        if deltaRows != 0 {
            bridge.scroll(delta: deltaRows)
            needsDisplay = true
        }
    }

    private func resolveColor(_ color: GhosttyStyleColor, colors: GhosttyRenderStateColors, fallback: GhosttyColorRgb) -> GhosttyColorRgb {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_RGB:
            return color.value.rgb
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let idx = Int(color.value.palette)
            return withUnsafeBytes(of: colors.palette) { raw in
                raw.bindMemory(to: GhosttyColorRgb.self)[idx]
            }
        default:
            return fallback
        }
    }
}
