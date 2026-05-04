import MetalKit
import GhosttyVt

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
    float4 color    [[attribute(2)]];
    uint   mode     [[attribute(3)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    uint   mode;
};

vertex VertexOut vert_main(Vertex in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv       = in.uv;
    out.color    = in.color;
    out.mode     = in.mode;
    return out;
}

fragment float4 frag_main(
    VertexOut      in        [[stage_in]],
    texture2d<float> grayTex [[texture(0)]],
    texture2d<float> colorTex[[texture(1)]],
    texture2d<float> imageTex[[texture(2)]]
) {
    constexpr sampler s(filter::linear);
    if (in.mode == 0u) {
        float a = grayTex.sample(s, in.uv).r;
        return float4(in.color.rgb, in.color.a * a);
    } else if (in.mode == 1u) {
        return colorTex.sample(s, in.uv);
    } else {
        return imageTex.sample(s, in.uv);
    }
}
"""

struct QuadVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
    var mode: UInt32
}

final class TerminalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var vertexBuffer: MTLBuffer
    private var vertices: [QuadVertex] = []
    private let maxVertices = 131_072

    // Current encoder for use by helper passes
    private var currentEncoder: MTLRenderCommandEncoder?
    // Running write offset into the vertex buffer (in vertices, not bytes)
    private var vertexWriteOffset = 0

    weak var termView: MetalTerminalView?
    private var atlas: GlyphAtlas!
    private var kittyCache: KittyTextureCache!

    // Scratch buffers for the row loop — hoisted to avoid per-frame heap allocations
    private struct CellInfo {
        var fgVec: SIMD4<Float>
        var bgVec: SIMD4<Float>?
    }
    private var cellInfos: [CellInfo] = []
    private var rowText = ""

    init(device: MTLDevice, view: MetalTerminalView) {
        self.device = device
        self.termView = view
        commandQueue = device.makeCommandQueue()!

        let library = try! device.makeLibrary(source: shaderSource, options: nil)
        let vertFn = library.makeFunction(name: "vert_main")!
        let fragFn = library.makeFunction(name: "frag_main")!

        let vd = MTLVertexDescriptor()
        // position: float2 @ offset 0
        vd.attributes[0].format = .float2
        vd.attributes[0].offset = 0
        vd.attributes[0].bufferIndex = 0
        // uv: float2 @ offset 8
        vd.attributes[1].format = .float2
        vd.attributes[1].offset = 8
        vd.attributes[1].bufferIndex = 0
        // color: float4 @ offset 16
        vd.attributes[2].format = .float4
        vd.attributes[2].offset = 16
        vd.attributes[2].bufferIndex = 0
        // mode: uint @ offset 32
        vd.attributes[3].format = .uint
        vd.attributes[3].offset = 32
        vd.attributes[3].bufferIndex = 0
        vd.layouts[0].stride = MemoryLayout<QuadVertex>.stride

        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = vertFn
        pd.fragmentFunction = fragFn
        pd.vertexDescriptor = vd
        pd.colorAttachments[0].pixelFormat = .bgra8Unorm
        pd.colorAttachments[0].isBlendingEnabled = true
        pd.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pd.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        pd.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try! device.makeRenderPipelineState(descriptor: pd)
        vertexBuffer = device.makeBuffer(
            length: MemoryLayout<QuadVertex>.stride * 131_072,
            options: .storageModeShared
        )!

        super.init()
        atlas = GlyphAtlas(device: device, font: view.font)
        kittyCache = KittyTextureCache(device: device)
    }

    func resize(width: Int, height: Int) {}

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: - NDC helpers

    private func ndcX(_ px: CGFloat, width: CGFloat) -> Float {
        Float(px / width * 2 - 1)
    }
    private func ndcY(_ py: CGFloat, height: CGFloat) -> Float {
        Float(py / height * 2 - 1)
    }

    private func emitQuad(
        x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
        u0: Float, v0: Float, u1: Float, v1: Float,
        color: SIMD4<Float>, mode: UInt32,
        vpW: CGFloat, vpH: CGFloat
    ) {
        let x0 = ndcX(x, width: vpW);   let y0 = ndcY(y, height: vpH)
        let x1 = ndcX(x + w, width: vpW); let y1 = ndcY(y + h, height: vpH)
        let tl = QuadVertex(position: .init(x0, y1), uv: .init(u0, v0), color: color, mode: mode)
        let tr = QuadVertex(position: .init(x1, y1), uv: .init(u1, v0), color: color, mode: mode)
        let bl = QuadVertex(position: .init(x0, y0), uv: .init(u0, v1), color: color, mode: mode)
        let br = QuadVertex(position: .init(x1, y0), uv: .init(u1, v1), color: color, mode: mode)
        vertices.append(tl)
        vertices.append(tr)
        vertices.append(bl)
        vertices.append(tr)
        vertices.append(br)
        vertices.append(bl)
    }

    // MARK: - Color resolver

    private func resolveColor(
        _ color: GhosttyStyleColor,
        colors: GhosttyRenderStateColors,
        fallback: GhosttyColorRgb
    ) -> GhosttyColorRgb {
        switch color.tag {
        case GHOSTTY_STYLE_COLOR_RGB:    return color.value.rgb
        case GHOSTTY_STYLE_COLOR_PALETTE:
            let idx = Int(color.value.palette)
            return withUnsafeBytes(of: colors.palette) { $0.bindMemory(to: GhosttyColorRgb.self)[idx] }
        default: return fallback
        }
    }

    // MARK: - Flush helpers

    /// Flush accumulated vertices to the GPU.
    private func flushVertices() {
        guard !vertices.isEmpty, let enc = currentEncoder else { return }
        let stride = MemoryLayout<QuadVertex>.stride
        let byteOffset = vertexWriteOffset * stride
        let byteCount = vertices.count * stride
        guard byteOffset + byteCount <= vertexBuffer.length else { return }
        vertexBuffer.contents().advanced(by: byteOffset).copyMemory(
            from: vertices, byteCount: byteCount
        )
        enc.setVertexBuffer(vertexBuffer, offset: byteOffset, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        vertexWriteOffset += vertices.count
        vertices.removeAll(keepingCapacity: true)
    }

    /// Emit Kitty image quads for all placements in the given layer.
    private func emitKittyPass(
        layer: GhosttyKittyPlacementLayer,
        graphics: GhosttyKittyGraphics,
        terminal: GhosttyTerminal,
        cellW: CGFloat, cellH: CGFloat,
        vpW: CGFloat, vpH: CGFloat
    ) {
        guard let enc = currentEncoder else { return }
        var iterHandle: GhosttyKittyGraphicsPlacementIterator?
        guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterHandle) == GHOSTTY_SUCCESS,
              let iter = iterHandle else { return }
        defer { ghostty_kitty_graphics_placement_iterator_free(iter) }

        var layerFilter = layer
        _ = ghostty_kitty_graphics_placement_iterator_set(
            iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &layerFilter
        )
        withUnsafeMutablePointer(to: &iterHandle) { ptr in
            _ = ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, UnsafeMutableRawPointer(ptr))
        }

        while ghostty_kitty_graphics_placement_next(iter) {
            var imageID: UInt32 = 0
            _ = ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)

            guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
            guard let tex = kittyCache.texture(for: imageID, graphics: graphics) else { continue }

            var info = GhosttyKittyGraphicsPlacementRenderInfo()
            info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
            guard ghostty_kitty_graphics_placement_render_info(iter, image, terminal, &info) == GHOSTTY_SUCCESS,
                  info.viewport_visible else { continue }

            // Flush pending text vertices before switching image texture
            if !vertices.isEmpty {
                flushVertices()
            }
            enc.setFragmentTexture(tex, index: 2)

            let destX = CGFloat(info.viewport_col) * cellW
            let destY = vpH - CGFloat(info.viewport_row + Int32(info.grid_rows)) * cellH
            let destW = CGFloat(info.pixel_width)
            let destH = CGFloat(info.pixel_height)

            let texW = Float(tex.width)
            let texH = Float(tex.height)
            let u0 = Float(info.source_x) / texW
            let v0 = Float(info.source_y) / texH
            let u1 = Float(info.source_x + info.source_width) / texW
            let v1 = Float(info.source_y + info.source_height) / texH

            emitQuad(x: destX, y: destY, w: destW, h: destH,
                     u0: u0, v0: v0, u1: u1, v1: v1,
                     color: .init(1, 1, 1, 1), mode: 2,
                     vpW: vpW, vpH: vpH)
            flushVertices()
        }
    }

    // MARK: - Draw

    func draw(in view: MTKView) {
        guard let tv = termView,
              let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor else { return }

        tv.bridge.updateRenderState()
        let colors = tv.bridge.colors
        let bg = colors.background
        rpd.colorAttachments[0].clearColor = MTLClearColor(
            red:   Double(bg.r) / 255,
            green: Double(bg.g) / 255,
            blue:  Double(bg.b) / 255,
            alpha: 1
        )
        rpd.colorAttachments[0].loadAction = .clear

        vertices.removeAll(keepingCapacity: true)
        vertexWriteOffset = 0

        let vpW = view.bounds.width
        let vpH = view.bounds.height
        let cw = tv.cellWidth
        let ch = tv.cellHeight

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        currentEncoder = enc
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(atlas.grayTexture, index: 0)
        enc.setFragmentTexture(atlas.colorTexture, index: 1)

        let runKittyPass = { [self] (layer: GhosttyKittyPlacementLayer) in
            tv.bridge.withKittyGraphics { graphics, terminal in
                self.emitKittyPass(
                    layer: layer, graphics: graphics, terminal: terminal,
                    cellW: cw, cellH: ch, vpW: vpW, vpH: vpH
                )
                self.flushVertices()
            }
        }

        // --- Kitty BELOW_BG pass ---
        runKittyPass(GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG)

        // --- Cell backgrounds and text ---
        tv.bridge.withRowIterator { iter, cellsHandle in
            var cells = cellsHandle
            var rowIndex = 0
            while ghostty_render_state_row_iterator_next(iter) {
                withUnsafeMutablePointer(to: &cells) { cp in
                    _ = ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, UnsafeMutableRawPointer(cp))
                }
                let rowY = vpH - CGFloat(rowIndex + 1) * ch

                cellInfos.removeAll(keepingCapacity: true)
                rowText.removeAll(keepingCapacity: true)

                while ghostty_render_state_row_cells_next(cells) {
                    var graphemeLen: UInt32 = 0
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen)
                    var style = GhosttyStyle()
                    style.size = MemoryLayout<GhosttyStyle>.size
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

                    var codepoints = [UInt32](repeating: 0, count: max(1, Int(graphemeLen)))
                    if graphemeLen > 0 {
                        _ = codepoints.withUnsafeMutableBufferPointer { buf in
                            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, UnsafeMutableRawPointer(buf.baseAddress!))
                        }
                    }

                    let textScalar: Unicode.Scalar
                    if graphemeLen > 0, let s = Unicode.Scalar(codepoints[0]) {
                        textScalar = s
                    } else {
                        textScalar = Unicode.Scalar(0x20)!
                    }
                    rowText.unicodeScalars.append(textScalar)

                    let fg = resolveColor(style.fg_color, colors: colors, fallback: colors.foreground)
                    let fgVec = SIMD4<Float>(Float(fg.r)/255, Float(fg.g)/255, Float(fg.b)/255, 1)

                    let cellBg = resolveColor(style.bg_color, colors: colors, fallback: bg)
                    let bgVec: SIMD4<Float>?
                    if cellBg.r != bg.r || cellBg.g != bg.g || cellBg.b != bg.b {
                        bgVec = SIMD4<Float>(Float(cellBg.r)/255, Float(cellBg.g)/255, Float(cellBg.b)/255, 1)
                    } else {
                        bgVec = nil
                    }
                    cellInfos.append(CellInfo(fgVec: fgVec, bgVec: bgVec))
                }

                // Emit backgrounds
                for (col, info) in cellInfos.enumerated() {
                    let cellX = CGFloat(col) * cw
                    if let bgColor = info.bgVec {
                        let se = atlas.solidEntry
                        emitQuad(x: cellX, y: rowY, w: cw, h: ch,
                                 u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                                 color: bgColor, mode: 0, vpW: vpW, vpH: vpH)
                    }
                }

                rowIndex += 1
                // Store rowText and cellInfos for text pass below
                // We do text in the same loop to avoid re-iterating
                let rowGlyphs = atlas.layoutRow(text: rowText, cellWidth: cw)
                let savedRowY = rowY
                for (col, info) in cellInfos.enumerated() {
                    let cellX = CGFloat(col) * cw
                    if let rowGlyph = rowGlyphs[col] {
                        let entry = rowGlyph.entry
                        let glyphY = savedRowY + (ch - CGFloat(entry.pixelHeight)) / 2
                        emitQuad(
                            x: cellX, y: glyphY,
                            w: CGFloat(entry.pixelWidth), h: CGFloat(entry.pixelHeight),
                            u0: entry.u0, v0: entry.v0, u1: entry.u1, v1: entry.v1,
                            color: rowGlyph.isColor ? .init(1,1,1,1) : info.fgVec,
                            mode: rowGlyph.isColor ? 1 : 0,
                            vpW: vpW, vpH: vpH
                        )
                    }
                }

                var clean = false
                ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
            }
        }

        // Flush text/bg vertices before below-text Kitty pass
        flushVertices()

        // --- Kitty BELOW_TEXT pass ---
        runKittyPass(GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT)

        // --- Cursor ---
        if let cursor = tv.bridge.cursorState() {
            let cx = CGFloat(cursor.x) * cw
            let cy = vpH - CGFloat(cursor.y + 1) * ch
            let white = SIMD4<Float>(1, 1, 1, 0.8)
            let se = atlas.solidEntry
            switch cursor.style {
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK:
                emitQuad(x: cx, y: cy, w: cw, h: ch,
                         u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                         color: white, mode: 0, vpW: vpW, vpH: vpH)
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR:
                emitQuad(x: cx, y: cy, w: 2, h: ch,
                         u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                         color: white, mode: 0, vpW: vpW, vpH: vpH)
            case GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE:
                emitQuad(x: cx, y: cy, w: cw, h: 2,
                         u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                         color: white, mode: 0, vpW: vpW, vpH: vpH)
            default:
                emitQuad(x: cx, y: cy, w: cw, h: ch,
                         u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                         color: white, mode: 0, vpW: vpW, vpH: vpH)
            }
        }
        flushVertices()

        // --- Kitty ABOVE_TEXT pass ---
        runKittyPass(GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT)

        enc.endEncoding()
        currentEncoder = nil
        cb.present(drawable)
        cb.commit()

        tv.bridge.clearDirty()
    }
}
