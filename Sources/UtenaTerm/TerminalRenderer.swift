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

    weak var termView: MetalTerminalView?
    private let font: CTFont
    private var atlas: GlyphAtlas!

    init(device: MTLDevice, view: MetalTerminalView) {
        self.device = device
        self.termView = view
        self.font = view.font
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
        atlas = GlyphAtlas(device: device, font: font)
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
        vertices += [tl, tr, bl, tr, br, bl]
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

        let vpW = view.drawableSize.width
        let vpH = view.drawableSize.height
        let cw = tv.cellWidth
        let ch = tv.cellHeight

        tv.bridge.withRowIterator { iter, cellsHandle in
            var cells = cellsHandle
            var rowIndex = 0
            while ghostty_render_state_row_iterator_next(iter) {
                withUnsafeMutablePointer(to: &cells) { cp in
                    _ = ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, UnsafeMutableRawPointer(cp))
                }
                let rowY = vpH - CGFloat(rowIndex + 1) * ch

                // --- Pass 1: collect cell data + build row text for CoreText ---
                struct CellInfo {
                    var graphemeCPs: [UInt32]
                    var fgVec: SIMD4<Float>
                    var bgVec: SIMD4<Float>?   // non-nil if differs from terminal bg
                }
                var cellInfos: [CellInfo] = []
                var rowText = ""

                // Rewind by re-populating cells; the iterator is already at this row.
                // We iterate cells once to build rowText and collect style/grapheme data.
                var colIndex = 0
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

                    // Build row text: use the first codepoint or a space for empty cells
                    let textScalar: Unicode.Scalar
                    if graphemeLen > 0, let s = Unicode.Scalar(codepoints[0]) {
                        textScalar = s
                    } else {
                        textScalar = Unicode.Scalar(0x20)! // space
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

                    cellInfos.append(CellInfo(
                        graphemeCPs: graphemeLen > 0 ? Array(codepoints.prefix(Int(graphemeLen))) : [],
                        fgVec: fgVec,
                        bgVec: bgVec
                    ))
                    colIndex += 1
                }

                // --- CoreText layout for this row ---
                let rowGlyphs = atlas.layoutRow(text: rowText, cellWidth: cw)

                // --- Pass 2: emit quads ---
                for (col, info) in cellInfos.enumerated() {
                    let cellX = CGFloat(col) * cw

                    // Background
                    if let bgColor = info.bgVec {
                        let se = atlas.solidEntry
                        emitQuad(x: cellX, y: rowY, w: cw, h: ch,
                                 u0: se.u0, v0: se.v0, u1: se.u1, v1: se.v1,
                                 color: bgColor, mode: 0, vpW: vpW, vpH: vpH)
                    }

                    // Glyph — from CoreText row layout
                    if let rowGlyph = rowGlyphs[col] {
                        let entry = rowGlyph.entry
                        let glyphY = rowY + (ch - CGFloat(entry.pixelHeight)) / 2
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
                rowIndex += 1
            }
        }

        // Cursor
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

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(atlas.grayTexture, index: 0)
        enc.setFragmentTexture(atlas.colorTexture, index: 1)
        // index 2 (Kitty) will be added in Task 11

        if !vertices.isEmpty {
            vertexBuffer.contents().copyMemory(
                from: vertices,
                byteCount: MemoryLayout<QuadVertex>.stride * vertices.count
            )
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        enc.endEncoding()
        cb.present(drawable)
        cb.commit()

        tv.bridge.clearDirty()
    }
}
