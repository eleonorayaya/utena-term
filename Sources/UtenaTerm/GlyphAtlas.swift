import CoreText
import CoreGraphics
import Metal

struct AtlasEntry {
    var u0, v0, u1, v1: Float   // UV coordinates in [0, 1]
    var pointWidth: Int   // emit-quad width in points
    var pointHeight: Int  // emit-quad height in points
    var pixelWidth: Int   // texture storage in atlas pixels (for layout/UV)
    var pixelHeight: Int  // texture storage in atlas pixels
}

final class GlyphAtlas {
    static let atlasSize = 2048

    let device: MTLDevice
    let font: CTFont
    let backingScale: CGFloat

    let cellAscent: CGFloat
    let cellDescent: CGFloat
    let cellHeight: CGFloat
    let cellWidth: CGFloat

    private struct ShelfPacker {
        var shelfX = 0
        var shelfY = 0
        var shelfHeight = 0

        mutating func alloc(w: Int, h: Int, atlasSize: Int) -> (Int, Int)? {
            if shelfX + w > atlasSize {
                shelfY += shelfHeight + 1
                shelfX = 0
                shelfHeight = 0
            }
            if shelfY + h > atlasSize { return nil }
            let x = shelfX
            let y = shelfY
            shelfX += w + 1
            shelfHeight = max(shelfHeight, h)
            return (x, y)
        }
    }

    // Grayscale atlas for outline glyphs
    private(set) var grayTexture: MTLTexture
    private var grayCache: [UInt32: AtlasEntry] = [:]
    private var grayPacker = ShelfPacker()

    // Color atlas for emoji / color glyphs
    private(set) var colorTexture: MTLTexture
    private var colorCache: [UInt32: AtlasEntry] = [:]
    private var colorPacker = ShelfPacker()

    // cellWidth/cellHeight are passed in (rather than re-derived) so the atlas uses the same
    // device-pixel-snapped values as the renderer; otherwise rounding differences between
    // here and MetalTerminalView produce subtle alignment drift.
    init(device: MTLDevice, font: CTFont, cellWidth: CGFloat, cellHeight: CGFloat, backingScale: CGFloat = 1.0) {
        self.device = device
        self.font = font
        self.backingScale = backingScale

        cellAscent = CTFontGetAscent(font)
        cellDescent = CTFontGetDescent(font)
        self.cellHeight = cellHeight
        self.cellWidth = cellWidth

        let sz = GlyphAtlas.atlasSize
        let gd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: sz, height: sz, mipmapped: false
        )
        gd.usage = MTLTextureUsage([.shaderRead, .shaderWrite])
        gd.storageMode = .shared
        grayTexture = device.makeTexture(descriptor: gd)!

        let cd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: sz, height: sz, mipmapped: false
        )
        cd.usage = MTLTextureUsage([.shaderRead, .shaderWrite])
        cd.storageMode = .shared
        colorTexture = device.makeTexture(descriptor: cd)!

        // Reserve a 1x1 white pixel at (0,0) for solid fills
        let white: [UInt8] = [255]
        grayTexture.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: 1, height: 1, depth: 1)),
            mipmapLevel: 0, withBytes: white, bytesPerRow: 1
        )
        grayPacker.shelfX = 2 // skip the 1x1 slot
    }

    var solidEntry: AtlasEntry { AtlasEntry(u0: 0, v0: 0, u1: 1/Float(Self.atlasSize), v1: 1/Float(Self.atlasSize), pointWidth: 1, pointHeight: 1, pixelWidth: 1, pixelHeight: 1) }

    /// Lookup or rasterize the atlas entry for a glyph. The cache key encodes color and
    /// icon-fit variants so the same glyph index can have distinct rasterizations.
    func entry(forGlyph glyph: CGGlyph, font: CTFont, isIcon: Bool) -> (AtlasEntry, Bool)? {
        let isColor = CTFontCreatePathForGlyph(font, glyph, nil) == nil
        let cacheKey = UInt32(glyph)
            | (isColor ? 0x8000_0000 : 0)
            | (isIcon ? 0x4000_0000 : 0)
        if isColor, let e = colorCache[cacheKey] { return (e, true) }
        if !isColor, let e = grayCache[cacheKey] { return (e, false) }
        guard let e = rasterizeCore(glyph: glyph, glyphFont: font, color: isColor, isIcon: isIcon) else { return nil }
        if isColor { colorCache[cacheKey] = e } else { grayCache[cacheKey] = e }
        return (e, isColor)
    }

    private struct IconFit {
        var canvasPointW: Int
        var scale: CGFloat
        var tx: CGFloat
        var ty: CGFloat
    }
    // Canvas anchors to the cell's left edge (no left pad) so col-0 icons stay on screen and
    // an icon's left edge aligns with regular text in the same column. Half-cell right pad
    // keeps the icon from kissing the following character.
    private func iconFit(glyph: CGGlyph, glyphFont: CTFont) -> IconFit? {
        var g = glyph
        var bbox = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(glyphFont, .horizontal, &g, &bbox, 1)
        guard bbox.width > 0, bbox.height > 0 else { return nil }
        let scale = (cellHeight * 0.75) / bbox.height
        let scaledW = bbox.width * scale
        let canvasW = max(cellWidth, ceil(scaledW + cellWidth * 0.5))
        let tx = -bbox.minX * scale
        let ty = (cellHeight - bbox.height * scale) / 2 - bbox.minY * scale
        return IconFit(canvasPointW: Int(canvasW), scale: scale, tx: tx, ty: ty)
    }

    private func applyGlyphTransform(_ ctx: CGContext, fit: IconFit?) {
        if let fit {
            ctx.translateBy(x: fit.tx, y: fit.ty)
            ctx.scaleBy(x: fit.scale, y: fit.scale)
        } else {
            ctx.translateBy(x: 0, y: cellDescent)
        }
    }

    private func rasterizeCore(glyph: CGGlyph, glyphFont: CTFont, color: Bool, isIcon: Bool = false) -> AtlasEntry? {
        var g = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(glyphFont, .horizontal, &g, &advance, 1)
        let scale = backingScale
        let fit: IconFit? = isIcon ? iconFit(glyph: g, glyphFont: glyphFont) : nil
        let pointW = max(1, fit?.canvasPointW ?? Int(ceil(advance.width)))
        let pointH = max(1, Int(ceil(cellHeight)))
        let pixelW = max(1, Int(ceil(CGFloat(pointW) * scale)))
        let pixelH = max(1, Int(ceil(CGFloat(pointH) * scale)))
        let s = Self.atlasSize

        if color {
            var pixels = [UInt8](repeating: 0, count: pixelW * pixelH * 4)
            guard let ctx = CGContext(
                data: &pixels, width: pixelW, height: pixelH,
                bitsPerComponent: 8, bytesPerRow: pixelW * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return nil }
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.scaleBy(x: scale, y: scale)
            applyGlyphTransform(ctx, fit: fit)
            CTFontDrawGlyphs(glyphFont, &g, [.zero], 1, ctx)
            guard let slot = allocColorSlot(w: pixelW, h: pixelH) else { return nil }
            let (x, y) = slot
            pixels.withUnsafeBytes { raw in
                colorTexture.replace(
                    region: MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                      size: MTLSize(width: pixelW, height: pixelH, depth: 1)),
                    mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: pixelW * 4
                )
            }
            return AtlasEntry(
                u0: Float(x)/Float(s), v0: Float(y)/Float(s),
                u1: Float(x+pixelW)/Float(s), v1: Float(y+pixelH)/Float(s),
                pointWidth: pointW, pointHeight: pointH,
                pixelWidth: pixelW, pixelHeight: pixelH
            )
        } else {
            var pixels = [UInt8](repeating: 0, count: pixelW * pixelH)
            guard let ctx = CGContext(
                data: &pixels, width: pixelW, height: pixelH,
                bitsPerComponent: 8, bytesPerRow: pixelW,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else { return nil }
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.scaleBy(x: scale, y: scale)
            applyGlyphTransform(ctx, fit: fit)
            CTFontDrawGlyphs(glyphFont, &g, [.zero], 1, ctx)
            guard let slot = allocGraySlot(w: pixelW, h: pixelH) else { return nil }
            let (x, y) = slot
            pixels.withUnsafeBytes { raw in
                grayTexture.replace(
                    region: MTLRegion(origin: MTLOrigin(x: x, y: y, z: 0),
                                      size: MTLSize(width: pixelW, height: pixelH, depth: 1)),
                    mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: pixelW
                )
            }
            return AtlasEntry(
                u0: Float(x)/Float(s), v0: Float(y)/Float(s),
                u1: Float(x+pixelW)/Float(s), v1: Float(y+pixelH)/Float(s),
                pointWidth: pointW, pointHeight: pointH,
                pixelWidth: pixelW, pixelHeight: pixelH
            )
        }
    }

    private func allocGraySlot(w: Int, h: Int) -> (Int, Int)? {
        grayPacker.alloc(w: w, h: h, atlasSize: Self.atlasSize)
    }

    private func allocColorSlot(w: Int, h: Int) -> (Int, Int)? {
        colorPacker.alloc(w: w, h: h, atlasSize: Self.atlasSize)
    }

    struct RowGlyph {
        var glyphIndex: CGGlyph
        var isColor: Bool
        var entry: AtlasEntry
        var colSpan: Int       // number of cells this glyph covers (>=1)
        var xOffset: CGFloat   // pixel offset from cell left edge
        var yOffset: CGFloat   // pixel offset from cell bottom edge
    }
}
