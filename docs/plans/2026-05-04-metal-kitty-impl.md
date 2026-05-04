# Metal Rendering + Kitty Graphics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the Core Graphics terminal renderer with a Metal-based renderer using a dual glyph atlas, and add Kitty graphics protocol image rendering.

**Architecture:** `TerminalView: NSView` is replaced by `MetalTerminalView: MTKView`. A `TerminalRenderer` owns the Metal device, command queue, and vertex buffer. A `GlyphAtlas` handles row-level CoreText layout into a dual `r8Unorm`/`rgba8Unorm` atlas. A `KittyTextureCache` maps ghostty-vt image IDs to `MTLTexture`. Metal shaders are compiled at startup via `device.makeLibrary(source:options:)` (SPM-compatible; no `.metal` file needed).

**Tech Stack:** Swift, MetalKit (`MTKView`, `MTKViewDelegate`), CoreText, ImageIO, AppKit, libghostty-vt

**Reference:** Design doc at `docs/plans/2026-05-04-metal-kitty-design.md`

---

### Task 1: Link MetalKit in Package.swift

**Files:**
- Modify: `Package.swift`

**Step 1: Add MetalKit and Metal linker settings**

Replace the `executableTarget` in `Package.swift`:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "utena-term",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "utena-term",
            dependencies: ["GhosttyVt"],
            path: "Sources/UtenaTerm",
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .binaryTarget(name: "GhosttyVt", path: "Frameworks/ghostty-vt.xcframework"),
    ]
)
```

**Step 2: Verify it builds**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!` (no new errors — we haven't imported anything yet)

**Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: link Metal, MetalKit, ImageIO frameworks"
```

---

### Task 2: MetalTerminalView scaffold

**Files:**
- Create: `Sources/UtenaTerm/MetalTerminalView.swift`
- Modify: `Sources/UtenaTerm/TerminalPane.swift`

**Context:** `MTKView` is an `NSView` subclass so it slots directly into the existing view hierarchy. We move all input/focus/resize logic from `TerminalView` here, but render nothing yet (just clears to black). `TerminalView.swift` is left untouched until the end.

**Step 1: Create MetalTerminalView.swift**

```swift
import AppKit
import MetalKit
import GhosttyVt

final class MetalTerminalView: MTKView {
    var bridge: GhosttyBridge!
    var onInput: ((Data) -> Void)?
    var onResize: ((UInt16, UInt16) -> Void)?
    var onFocus: (() -> Void)?
    var isActive: Bool = false { didSet { setNeedsDisplay(bounds) } }

    private let font: CTFont
    var cellWidth: CGFloat = 0
    var cellHeight: CGFloat = 0
    private var cellAscent: CGFloat = 0
    var renderer: TerminalRenderer?

    override init(frame: NSRect, device: MTLDevice?) {
        font = CTFontCreateWithName("Menlo" as CFString, 13, nil)
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
        cellHeight = ascent + descent + leading
        var glyph: CGGlyph = 0
        var ch: UniChar = UniChar(UInt8(ascii: "M"))
        CTFontGetGlyphsForCharacters(font, &ch, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        cellWidth = advance.width
    }

    var gridCols: UInt16 { UInt16(max(1, Int(bounds.width / cellWidth))) }
    var gridRows: UInt16 { UInt16(max(1, Int(bounds.height / cellHeight))) }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        renderer?.resize(width: Int(newSize.width), height: Int(newSize.height))
        bridge?.resize(cols: gridCols, rows: gridRows)
        onResize?(gridCols, gridRows)
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
```

**Step 2: Modify TerminalPane.swift to use MetalTerminalView**

Replace the `view: TerminalView` property and init body:

```swift
import AppKit
import Metal

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
        pty = PtyManager()
        pty.onData = { [weak self] data in
            guard let self else { return }
            self.bridge.write(data)
            self.view.setNeedsDisplay(self.view.bounds)
        }
        view.onInput = { [weak self] data in self?.pty.write(data) }
        view.onResize = { [weak self] cols, rows in self?.pty.resize(cols: cols, rows: rows) }
        pty.start(cols: cols, rows: rows)
    }

    func resize(cols: UInt16, rows: UInt16) {
        bridge.resize(cols: cols, rows: rows)
        pty.resize(cols: cols, rows: rows)
    }
}
```

**Note:** `TerminalRenderer` doesn't exist yet so the build will fail. That's expected. Continue to Task 3.

---

### Task 3: TerminalRenderer — Metal device, pipelines, clear pass

**Files:**
- Create: `Sources/UtenaTerm/TerminalRenderer.swift`

**Context:** The renderer compiles shaders from an embedded source string (SPM-compatible — no `.metal` file needed). For now it just clears to the terminal background color. Text and image rendering come in later tasks.

The vertex format (mode 0 = grayscale glyph, 1 = color glyph, 2 = Kitty image):

```
position: float2 (NDC)
uv:       float2
color:    float4
mode:     uint
```

**Step 1: Create TerminalRenderer.swift**

```swift
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
    }

    func resize(width: Int, height: Int) {}

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

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

        guard let cb = commandQueue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

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
```

**Step 2: Build and verify**

```bash
swift build 2>&1 | tail -10
```
Expected: `Build complete!`

**Step 3: Run and verify**

```bash
.build/debug/utena-term
```
Expected: Terminal window opens, background matches terminal theme color (no text yet, but no crash).

**Step 4: Commit**

```bash
git add Sources/UtenaTerm/MetalTerminalView.swift Sources/UtenaTerm/TerminalRenderer.swift Sources/UtenaTerm/TerminalPane.swift
git commit -m "feat: Metal scaffold — MTKView + clear pass renderer"
```

---

### Task 4: GlyphAtlas — grayscale shelf packer

**Files:**
- Create: `Sources/UtenaTerm/GlyphAtlas.swift`

**Context:** The atlas is a 2048×2048 `r8Unorm` texture for grayscale (outline) glyphs. A shelf packer tracks free rows. Each glyph is rasterized via CoreText into a `CGBitmapContext`, then uploaded to the texture. Cache key is `UInt32` (Unicode scalar). The color atlas (`rgba8Unorm`) is added in Task 7.

**Step 1: Create GlyphAtlas.swift**

```swift
import CoreText
import CoreGraphics
import Metal

struct AtlasEntry {
    var u0, v0, u1, v1: Float   // UV coordinates in [0, 1]
    var pixelWidth: Int
    var pixelHeight: Int
}

final class GlyphAtlas {
    static let atlasSize = 2048

    let device: MTLDevice
    let font: CTFont

    // Grayscale atlas for outline glyphs
    private(set) var grayTexture: MTLTexture
    private var grayCache: [UInt32: AtlasEntry] = [:]
    private var grayShelfX = 0
    private var grayShelfY = 0
    private var grayShelfHeight = 0

    // Color atlas for emoji / color glyphs (created lazily in Task 7)
    private(set) var colorTexture: MTLTexture
    private var colorCache: [UInt32: AtlasEntry] = [:]
    private var colorShelfX = 0
    private var colorShelfY = 0
    private var colorShelfHeight = 0

    init(device: MTLDevice, font: CTFont) {
        self.device = device
        self.font = font

        let gd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize, height: atlasSize, mipmapped: false
        )
        gd.usage = [.shaderRead, .shaderWrite]
        gd.storageMode = .shared
        grayTexture = device.makeTexture(descriptor: gd)!

        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: atlasSize, height: atlasSize, mipmapped: false
        )
        cd.usage = [.shaderRead, .shaderWrite]
        cd.storageMode = .shared
        colorTexture = device.makeTexture(descriptor: cd)!
    }

    // Returns true if this scalar's glyph is a color glyph (emoji etc.)
    func isColorGlyph(_ scalar: UInt32) -> Bool {
        var glyph: CGGlyph = 0
        var us = UniChar(scalar & 0xFFFF)
        guard CTFontGetGlyphsForCharacters(font, &us, &glyph, 1), glyph != 0 else { return false }
        return CTFontCreatePathForGlyph(font, glyph, nil) == nil
    }

    func entry(for scalar: UInt32) -> (AtlasEntry, Bool)? {
        let isColor = isColorGlyph(scalar)
        if isColor {
            if let e = colorCache[scalar] { return (e, true) }
            return rasterizeColor(scalar).map { ($0, true) }
        } else {
            if let e = grayCache[scalar] { return (e, false) }
            return rasterizeGray(scalar).map { ($0, false) }
        }
    }

    private func rasterizeGray(_ scalar: UInt32) -> AtlasEntry? {
        guard let (bitmap, w, h) = renderGlyph(scalar, color: false) else { return nil }
        guard let slot = allocGraySlot(w: w, h: h) else { return nil }
        let (x, y) = slot
        let s = Self.atlasSize
        bitmap.withUnsafeBytes { raw in
            grayTexture.replace(
                region: MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                  size: MTLSize(width: w, height: h, depth: 1)),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: w
            )
        }
        let entry = AtlasEntry(
            u0: Float(x) / Float(s), v0: Float(y) / Float(s),
            u1: Float(x + w) / Float(s), v1: Float(y + h) / Float(s),
            pixelWidth: w, pixelHeight: h
        )
        grayCache[scalar] = entry
        return entry
    }

    private func rasterizeColor(_ scalar: UInt32) -> AtlasEntry? {
        guard let (bitmap, w, h) = renderGlyph(scalar, color: true) else { return nil }
        guard let slot = allocColorSlot(w: w, h: h) else { return nil }
        let (x, y) = slot
        let s = Self.atlasSize
        bitmap.withUnsafeBytes { raw in
            colorTexture.replace(
                region: MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                  size: MTLSize(width: w, height: h, depth: 1)),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: w * 4
            )
        }
        let entry = AtlasEntry(
            u0: Float(x) / Float(s), v0: Float(y) / Float(s),
            u1: Float(x + w) / Float(s), v1: Float(y + h) / Float(s),
            pixelWidth: w, pixelHeight: h
        )
        colorCache[scalar] = entry
        return entry
    }

    private func renderGlyph(_ scalar: UInt32, color: Bool) -> ([UInt8], Int, Int)? {
        guard let us = Unicode.Scalar(scalar) else { return nil }
        let str = String(us) as CFString
        var glyph: CGGlyph = 0
        var ch = Array(String(us).utf16)
        guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, ch.count), glyph != 0 else { return nil }

        var bbox = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        let w = max(1, Int(ceil(bbox.width)) + 2)
        let h = max(1, Int(ceil(bbox.height)) + 2)

        if color {
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }
            ctx.translateBy(x: -bbox.minX + 1, y: -bbox.minY + 1)
            CTFontDrawGlyphs(font, &glyph, [.zero], 1, ctx)
            return (pixels, w, h)
        } else {
            var pixels = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return nil }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.translateBy(x: -bbox.minX + 1, y: -bbox.minY + 1)
            CTFontDrawGlyphs(font, &glyph, [.zero], 1, ctx)
            return (pixels, w, h)
        }
    }

    private func allocGraySlot(w: Int, h: Int) -> (Int, Int)? {
        let s = Self.atlasSize
        if grayShelfX + w > s {
            grayShelfY += grayShelfHeight + 1
            grayShelfX = 0
            grayShelfHeight = 0
        }
        if grayShelfY + h > s { return nil }
        let x = grayShelfX
        let y = grayShelfY
        grayShelfX += w + 1
        grayShelfHeight = max(grayShelfHeight, h)
        return (x, y)
    }

    private func allocColorSlot(w: Int, h: Int) -> (Int, Int)? {
        let s = Self.atlasSize
        if colorShelfX + w > s {
            colorShelfY += colorShelfHeight + 1
            colorShelfX = 0
            colorShelfHeight = 0
        }
        if colorShelfY + h > s { return nil }
        let x = colorShelfX
        let y = colorShelfY
        colorShelfX += w + 1
        colorShelfHeight = max(colorShelfHeight, h)
        return (x, y)
    }
}
```

**Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/UtenaTerm/GlyphAtlas.swift
git commit -m "feat: dual glyph atlas (grayscale + color) with shelf packer"
```

---

### Task 5: TerminalRenderer — text rendering

**Files:**
- Modify: `Sources/UtenaTerm/TerminalRenderer.swift`

**Context:** Add a `GlyphAtlas` to `TerminalRenderer`. In `draw(in:)`, after clearing, walk the render state rows and emit glyph quads. Helper `emitQuad` appends 6 vertices (2 triangles) for a cell-sized rectangle.

**Step 1: Add atlas property and quad helper to TerminalRenderer**

Add to `TerminalRenderer`:

```swift
private var atlas: GlyphAtlas!

// Call this after super.init() in TerminalRenderer.init
// atlas = GlyphAtlas(device: device, font: tv.font) -- but font is on view
// Instead, store font separately:
private let font: CTFont
```

Replace the `init` signature and beginning:

```swift
init(device: MTLDevice, view: MetalTerminalView) {
    self.device = device
    self.termView = view
    self.font = view.font  // need to expose font on MetalTerminalView
    // ... rest of init unchanged ...
    super.init()
    atlas = GlyphAtlas(device: device, font: font)
}
```

**Note:** Expose `font` on `MetalTerminalView` by changing `private let font` to `let font`.

**Step 2: Add emitQuad and emitBackground helpers**

Add to `TerminalRenderer`:

```swift
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
```

**Step 3: Add resolveColor helper and cell/row rendering to draw(in:)**

Add `resolveColor` (same logic as old `TerminalView`):

```swift
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
```

Replace the empty vertex-building section in `draw(in:)` with:

```swift
let vpW = view.drawableSize.width
let vpH = view.drawableSize.height
let cw = tv.cellWidth
let ch = tv.cellHeight
let ascent = tv.cellAscent  // expose cellAscent on MetalTerminalView

tv.bridge.withRowIterator { iter, cellsHandle in
    var cells = cellsHandle
    var rowIndex = 0
    while ghostty_render_state_row_iterator_next(iter) {
        withUnsafeMutablePointer(to: &cells) { cp in
            _ = ghostty_render_state_row_get(iter, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, UnsafeMutableRawPointer(cp))
        }
        let rowY = vpH - CGFloat(rowIndex + 1) * ch
        var colIndex = 0
        while ghostty_render_state_row_cells_next(cells) {
            defer { colIndex += 1 }
            var graphemeLen: UInt32 = 0
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &graphemeLen)
            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)

            let cellX = CGFloat(colIndex) * cw
            let colors = tv.bridge.colors

            // Background
            let cellBg = resolveColor(style.bg_color, colors: colors, fallback: colors.background)
            let bg = colors.background
            if cellBg.r != bg.r || cellBg.g != bg.g || cellBg.b != bg.b {
                let bgColor = SIMD4<Float>(Float(cellBg.r)/255, Float(cellBg.g)/255, Float(cellBg.b)/255, 1)
                emitQuad(x: cellX, y: rowY, w: cw, h: ch,
                         u0: 0, v0: 0, u1: 1, v1: 1,
                         color: bgColor, mode: 0, vpW: vpW, vpH: vpH)
            }

            // Glyph
            if graphemeLen > 0 {
                var codepoints = [UInt32](repeating: 0, count: Int(graphemeLen))
                _ = codepoints.withUnsafeMutableBufferPointer { buf in
                    ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, UnsafeMutableRawPointer(buf.baseAddress!))
                }
                let fg = resolveColor(style.fg_color, colors: colors, fallback: colors.foreground)
                let fgVec = SIMD4<Float>(Float(fg.r)/255, Float(fg.g)/255, Float(fg.b)/255, 1)

                for cp in codepoints.prefix(Int(graphemeLen)) {
                    guard let (entry, isColor) = atlas.entry(for: cp) else { continue }
                    let glyphY = rowY + (ch - CGFloat(entry.pixelHeight)) / 2
                    emitQuad(
                        x: cellX, y: glyphY,
                        w: CGFloat(entry.pixelWidth), h: CGFloat(entry.pixelHeight),
                        u0: entry.u0, v0: entry.v0, u1: entry.u1, v1: entry.v1,
                        color: isColor ? .init(1,1,1,1) : fgVec,
                        mode: isColor ? 1 : 0,
                        vpW: vpW, vpH: vpH
                    )
                    break // one glyph per cell for now
                }
            }
        }

        var clean = false
        ghostty_render_state_row_set(iter, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        rowIndex += 1
    }
}
```

**Step 4: Bind atlas textures before draw call**

In `draw(in:)`, before `enc.drawPrimitives`, add:

```swift
enc.setFragmentTexture(atlas.grayTexture, index: 0)
enc.setFragmentTexture(atlas.colorTexture, index: 1)
// index 2 (Kitty) will be added in Task 11
```

**Step 5: Also expose `cellAscent` as internal on MetalTerminalView**

Change `private var cellAscent` to `var cellAscent` in `MetalTerminalView`.

**Step 6: Build and run**

```bash
swift build 2>&1 | tail -5
.build/debug/utena-term
```
Expected: Terminal shows text. It may look slightly off vertically — that's fine, cursor comes next.

**Step 7: Commit**

```bash
git add Sources/UtenaTerm/TerminalRenderer.swift Sources/UtenaTerm/MetalTerminalView.swift
git commit -m "feat: Metal text rendering via glyph atlas"
```

---

### Task 6: Cursor rendering

**Files:**
- Modify: `Sources/UtenaTerm/TerminalRenderer.swift`

**Context:** After the row loop, emit cursor geometry. Cursor is a solid or hollow rectangle. Use mode=0 with a 1×1 white atlas entry — or use a dedicated background-fill path (no texture needed for solid fills, but easiest to just use the existing quad path with a 1×1 white pixel in the atlas).

**Step 1: Add a 1×1 white pixel to the grayscale atlas at init**

In `GlyphAtlas.init`, after creating textures, add:

```swift
// Reserve a 1x1 white pixel at (0,0) for solid fills
let white: [UInt8] = [255]
grayTexture.replace(
    region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                      size: MTLSize(width: 1, height: 1, depth: 1)),
    mipmapLevel: 0, withBytes: white, bytesPerRow: 1
)
grayShelfX = 2 // skip the 1x1 slot
```

Add a property: `var solidEntry: AtlasEntry { AtlasEntry(u0: 0, v0: 0, u1: 1/Float(Self.atlasSize), v1: 1/Float(Self.atlasSize), pixelWidth: 1, pixelHeight: 1) }`

**Step 2: Emit cursor quad in draw(in:)**

After the row iterator loop in `draw(in:)`:

```swift
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
```

**Step 3: Build and run**

```bash
swift build 2>&1 | tail -5 && .build/debug/utena-term
```
Expected: Cursor visible, text fully usable.

**Step 4: Commit**

```bash
git add Sources/UtenaTerm/TerminalRenderer.swift Sources/UtenaTerm/GlyphAtlas.swift
git commit -m "feat: cursor rendering in Metal renderer"
```

---

### Task 7: Ligature support via row-level CoreText layout

**Files:**
- Modify: `Sources/UtenaTerm/GlyphAtlas.swift`
- Modify: `Sources/UtenaTerm/TerminalRenderer.swift`

**Context:** Instead of looking up one scalar per cell independently, process each row as a `CTLine`. This gives us ligatures (multi-cell glyphs) and proper font fallback. The row text and the existing per-cell grapheme data from ghostty-vt are used together: ghostty-vt tells us what Unicode content is in each cell; CoreText tells us how to shape and render it.

**Step 1: Add row layout to GlyphAtlas**

Add to `GlyphAtlas`:

```swift
struct RowGlyph {
    var glyphIndex: CGGlyph
    var isColor: Bool
    var entry: AtlasEntry
    var colSpan: Int         // number of cells this glyph covers (>=1)
    var xOffset: CGFloat     // pixel offset from cell left edge
    var yOffset: CGFloat     // pixel offset from cell bottom edge
}

private var rowCache: [String: [Int: RowGlyph]] = [:]  // rowKey -> col -> glyph

func layoutRow(text: String, colors: GhosttyRenderStateColors) -> [Int: RowGlyph] {
    if let cached = rowCache[text] { return cached }

    let attrs: [CFString: Any] = [kCTFontAttributeName: font]
    let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attrStr)
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]

    var result: [Int: RowGlyph] = [:]
    let cellW = CTFontGetAdvancesForGlyphs(font, .horizontal, nil, nil, 0)  // not useful here

    // Build a character-index → column mapping from the UTF-16 string
    // (simple: one column per UnicodeScalar, assuming NFC text from ghostty)
    var col = 0
    var charToCol: [Int: Int] = [:]  // UTF-16 offset → column
    for scalar in text.unicodeScalars {
        let utf16len = scalar.utf16.count
        charToCol[charToCol.count] = col
        if utf16len == 2 { charToCol[charToCol.count] = col }  // surrogate pair
        col += 1
    }

    for run in runs {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)

        for i in 0..<count {
            let glyph = glyphs[i]
            let strIdx = Int(indices[i])
            guard let glyphCol = charToCol[strIdx] else { continue }

            let isColor = CTFontCreatePathForGlyph(font, glyph, nil) == nil
            // rasterize and cache by glyph ID (not scalar, since ligatures share no scalar)
            let cacheKey = UInt32(glyph) | (isColor ? 0x8000_0000 : 0)
            let entry: AtlasEntry
            if isColor {
                if let e = colorCache[cacheKey] { entry = e }
                else if let e = rasterizeColorGlyph(glyph) {
                    colorCache[cacheKey] = e; entry = e
                } else { continue }
            } else {
                if let e = grayCache[cacheKey] { entry = e }
                else if let e = rasterizeGrayGlyph(glyph) {
                    grayCache[cacheKey] = e; entry = e
                } else { continue }
            }

            // Compute colSpan from advance
            let advW = advances[i].width
            let nominalCellW = Double(CTFontGetSize(font) * 0.6)  // approximate
            let colSpan = max(1, Int(round(advW / nominalCellW)))

            result[glyphCol] = RowGlyph(
                glyphIndex: glyph, isColor: isColor, entry: entry,
                colSpan: colSpan, xOffset: 0, yOffset: 0
            )
        }
    }

    rowCache[text] = result
    if rowCache.count > 512 { rowCache.removeAll() }  // simple eviction
    return result
}
```

Also add `rasterizeGrayGlyph(_ glyph: CGGlyph)` and `rasterizeColorGlyph(_ glyph: CGGlyph)` that work like the existing methods but take a pre-resolved `CGGlyph` instead of a scalar. The body is identical to `renderGlyph` except it uses the glyph directly with `CTFontGetBoundingRectsForGlyphs` and `CTFontDrawGlyphs`.

**Step 2: Build and run**

```bash
swift build 2>&1 | tail -5 && .build/debug/utena-term
```
Expected: Renders identically to before. Ligatures visible with Fira Code or similar.

**Step 3: Commit**

```bash
git add Sources/UtenaTerm/GlyphAtlas.swift Sources/UtenaTerm/TerminalRenderer.swift
git commit -m "feat: row-level CoreText layout for ligature and font-fallback support"
```

---

### Task 8: GhosttyBridge — Kitty init and PNG decode callback

**Files:**
- Modify: `Sources/UtenaTerm/GhosttyBridge.swift`

**Context:** Two additions:
1. Set `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` in terminal init (335 MB, same as kitty's default)
2. Register a process-global PNG decode callback via `ghostty_sys_set`. The callback decodes PNG bytes using ImageIO, allocates output via the provided `GhosttyAllocator`, and writes to a `GhosttySysImage`.
3. Add `withKittyGraphics(_ body:)` method.

The PNG callback must be a C function (not a closure) because it's a function pointer. Use a file-scope `func` with `@convention(c)`.

**Step 1: Register PNG decoder and Kitty storage in GhosttyBridge.init**

Add to `GhosttyBridge.init` after creating the terminal, before creating the render state:

```swift
// Enable Kitty graphics storage (335 MB)
var kittyLimit: UInt64 = 335 * 1024 * 1024
_ = ghostty_terminal_setopt(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyLimit)

// Register PNG decode callback (process-global, safe to call multiple times)
var decodeFn: GhosttySysDecodePngFn = ghosttyDecodePng
_ = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, &decodeFn)
```

**Step 2: Add the C-compatible PNG decode function at file scope**

Add outside the class, at the bottom of `GhosttyBridge.swift`:

```swift
import ImageIO

@convention(c)
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
    let pixelBuf = ghostty_alloc(allocator, byteCount)
    guard let pixelBuf else { return false }

    guard let ctx = CGContext(
        data: pixelBuf, width: w, height: h,
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
```

**Step 3: Add withKittyGraphics to GhosttyBridge**

```swift
func withKittyGraphics(_ body: (GhosttyKittyGraphics) -> Void) {
    var handle: GhosttyKittyGraphics?
    guard ghostty_terminal_get(
        terminal,
        GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS,
        &handle
    ) == GHOSTTY_SUCCESS, let h = handle else { return }
    body(h)
}
```

**Step 4: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

**Step 5: Commit**

```bash
git add Sources/UtenaTerm/GhosttyBridge.swift
git commit -m "feat: enable Kitty graphics — storage limit + PNG decode callback"
```

---

### Task 9: KittyTextureCache

**Files:**
- Create: `Sources/UtenaTerm/KittyTextureCache.swift`

**Context:** Maps Kitty image IDs to `MTLTexture`. Uploads on first reference using the pixel data pointer borrowed from ghostty-vt. Evicts when ghostty-vt reports an image gone (nil handle on lookup).

**Step 1: Create KittyTextureCache.swift**

```swift
import Metal
import GhosttyVt

final class KittyTextureCache {
    private let device: MTLDevice
    private var cache: [UInt32: MTLTexture] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    func texture(
        for imageID: UInt32,
        graphics: GhosttyKittyGraphics
    ) -> MTLTexture? {
        // Evict if image is gone
        if cache[imageID] != nil {
            if ghostty_kitty_graphics_image(graphics, imageID) == nil {
                cache.removeValue(forKey: imageID)
                return nil
            }
            return cache[imageID]
        }

        guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { return nil }

        var width: UInt32 = 0
        var height: UInt32 = 0
        var format = GHOSTTY_KITTY_IMAGE_FORMAT_RGBA
        var dataPtr: UnsafePointer<UInt8>? = nil
        var dataLen: Int = 0

        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &dataPtr)
        ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &dataLen)

        guard let pixels = dataPtr, width > 0, height > 0 else { return nil }

        let pixelFormat: MTLPixelFormat
        let bytesPerRow: Int
        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            pixelFormat = .rgba8Unorm; bytesPerRow = Int(width) * 4
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            // Metal doesn't have rgb8 — expand to rgba
            let expanded = expandRGBtoRGBA(pixels, count: Int(width * height))
            return makeAndCache(imageID: imageID, pixels: expanded,
                                width: Int(width), height: Int(height),
                                format: .rgba8Unorm, bytesPerRow: Int(width) * 4)
        default:
            return nil
        }

        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: Int(width), height: Int(height), mipmapped: false
        )
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(
            region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                              size: .init(width: Int(width), height: Int(height), depth: 1)),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        cache[imageID] = tex
        return tex
    }

    private func makeAndCache(
        imageID: UInt32, pixels: [UInt8],
        width: Int, height: Int,
        format: MTLPixelFormat, bytesPerRow: Int
    ) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        td.usage = .shaderRead; td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        pixels.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                                  size: .init(width: width, height: height, depth: 1)),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow
            )
        }
        cache[imageID] = tex
        return tex
    }

    private func expandRGBtoRGBA(_ src: UnsafePointer<UInt8>, count: Int) -> [UInt8] {
        var result = [UInt8](repeating: 255, count: count * 4)
        for i in 0..<count {
            result[i * 4 + 0] = src[i * 3 + 0]
            result[i * 4 + 1] = src[i * 3 + 1]
            result[i * 4 + 2] = src[i * 3 + 2]
        }
        return result
    }
}
```

**Step 2: Build**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!`

**Step 3: Commit**

```bash
git add Sources/UtenaTerm/KittyTextureCache.swift
git commit -m "feat: KittyTextureCache — Kitty image ID to MTLTexture"
```

---

### Task 10: TerminalRenderer — Kitty placement pass

**Files:**
- Modify: `Sources/UtenaTerm/TerminalRenderer.swift`

**Context:** Add `KittyTextureCache` to `TerminalRenderer`. In `draw(in:)`, add three Kitty passes (BELOW_BG, BELOW_TEXT, ABOVE_TEXT) at the correct points in the layer order. Each pass iterates placements, gets render info, looks up the image texture, and emits an image quad.

**Step 1: Add kittyCache to TerminalRenderer**

In `TerminalRenderer.init`:

```swift
private var kittyCache: KittyTextureCache!
// After super.init():
kittyCache = KittyTextureCache(device: device)
```

**Step 2: Add emitKittyPass helper**

```swift
private func emitKittyPass(
    layer: GhosttyKittyPlacementLayer,
    graphics: GhosttyKittyGraphics,
    terminal: GhosttyTerminal,  // needed for placement_render_info
    cellW: CGFloat, cellH: CGFloat,
    vpW: CGFloat, vpH: CGFloat
) {
    var iterHandle: GhosttyKittyGraphicsPlacementIterator?
    guard ghostty_kitty_graphics_placement_iterator_new(nil, &iterHandle) == GHOSTTY_SUCCESS,
          let iter = iterHandle else { return }
    defer { ghostty_kitty_graphics_placement_iterator_free(iter) }

    var layerFilter = layer
    _ = ghostty_kitty_graphics_placement_iterator_set(
        iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_ITERATOR_OPTION_LAYER, &layerFilter
    )
    _ = ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, iter)

    while ghostty_kitty_graphics_placement_next(iter) {
        var imageID: UInt32 = 0
        ghostty_kitty_graphics_placement_get(iter, GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &imageID)

        guard let image = ghostty_kitty_graphics_image(graphics, imageID) else { continue }
        guard let tex = kittyCache.texture(for: imageID, graphics: graphics) else { continue }

        var info = GhosttyKittyGraphicsPlacementRenderInfo()
        info.size = MemoryLayout<GhosttyKittyGraphicsPlacementRenderInfo>.size
        guard ghostty_kitty_graphics_placement_render_info(iter, image, terminal, &info) == GHOSTTY_SUCCESS,
              info.viewport_visible else { continue }

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

        // Bind this image's texture to slot 2 and flush current vertices first
        if !vertices.isEmpty {
            vertexBuffer.contents().copyMemory(
                from: vertices,
                byteCount: MemoryLayout<QuadVertex>.stride * vertices.count
            )
            currentEncoder?.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            vertices.removeAll(keepingCapacity: true)
        }
        currentEncoder?.setFragmentTexture(tex, index: 2)

        emitQuad(x: destX, y: destY, w: destW, h: destH,
                 u0: u0, v0: v0, u1: u1, v1: v1,
                 color: .init(1, 1, 1, 1), mode: 2,
                 vpW: vpW, vpH: vpH)
    }
}
```

**Note:** This requires storing the current `MTLRenderCommandEncoder` as a property (`currentEncoder`) on `TerminalRenderer` so the helper can flush and re-draw when the image texture changes. Add `private var currentEncoder: MTLRenderCommandEncoder?` and assign it after `cb.makeRenderCommandEncoder(...)`.

**Step 3: Wire up the three passes in draw(in:)**

In `draw(in:)`, around the existing rendering steps:

```swift
tv.bridge.withKittyGraphics { graphics in
    // Pass 1: below background
    emitKittyPass(layer: GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_BG, ...)
    flushVertices()

    // ... cell background quads ...
    // ... Pass 2: below text ...
    emitKittyPass(layer: GHOSTTY_KITTY_PLACEMENT_LAYER_BELOW_TEXT, ...)
    flushVertices()

    // ... row/glyph quads ...
    // ... cursor quad ...

    // Pass 3: above text
    emitKittyPass(layer: GHOSTTY_KITTY_PLACEMENT_LAYER_ABOVE_TEXT, ...)
}
```

Extract a `flushVertices()` helper that copies the vertex array to the buffer and calls `drawPrimitives`.

**Step 4: Build and run**

```bash
swift build 2>&1 | tail -5 && .build/debug/utena-term
```
Expected: Terminal works as before. Test Kitty images with:
```bash
# In the running terminal:
curl -s https://raw.githubusercontent.com/kovidgoyal/kitty/master/logo/kitty.png | kitty +kitten icat
# Or if kitten icat not available:
python3 -c "
import base64, sys
data = open('/path/to/image.png','rb').read()
b64 = base64.standard_b64encode(data).decode()
sys.stdout.write(f'\x1b_Ga=T,f=100,q=1;{b64}\x1b\\\\')
"
```
Expected: Image displays inline in the terminal.

**Step 5: Commit**

```bash
git add Sources/UtenaTerm/TerminalRenderer.swift
git commit -m "feat: Kitty graphics image rendering (below-bg, below-text, above-text layers)"
```

---

### Task 11: Remove TerminalView.swift

**Files:**
- Delete: `Sources/UtenaTerm/TerminalView.swift`

**Step 1: Delete the old renderer**

```bash
rm Sources/UtenaTerm/TerminalView.swift
```

**Step 2: Build to confirm nothing references it**

```bash
swift build 2>&1 | tail -5
```
Expected: `Build complete!` with no errors.

**Step 3: Run and verify full functionality**

```bash
.build/debug/utena-term
```
Verify:
- Text renders correctly (including emoji if tested)
- Cursor visible and correct style
- Scrollback works
- Split panes work
- Tmux control mode window works

**Step 4: Commit**

```bash
git add -u
git commit -m "chore: remove Core Graphics TerminalView — Metal renderer is primary"
```

---

## Done

All tasks complete. The terminal now uses Metal for all rendering with a dual glyph atlas (grayscale + color/emoji), row-level CoreText layout for ligatures and font fallback, and Kitty graphics protocol image display with proper z-layering.
