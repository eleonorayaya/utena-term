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

    // Returns true if this scalar's glyph is a color glyph (emoji etc.)
    func isColorGlyph(_ scalar: UInt32) -> Bool {
        var glyph: CGGlyph = 0
        var us = UniChar(scalar & 0xFFFF)
        guard CTFontGetGlyphsForCharacters(font, &us, &glyph, 1), glyph != 0 else { return false }
        return CTFontCreatePathForGlyph(font, glyph, nil) == nil
    }

    func entry(for scalar: UInt32) -> (AtlasEntry, Bool)? {
        if let e = grayCache[scalar] { return (e, false) }
        if let e = colorCache[scalar] { return (e, true) }
        let isColor = isColorGlyph(scalar)
        return rasterize(scalar: scalar, color: isColor).map { ($0, isColor) }
    }

    private func rasterize(scalar: UInt32, color: Bool) -> AtlasEntry? {
        guard let us = Unicode.Scalar(scalar) else { return nil }
        var glyph: CGGlyph = 0
        var ch = Array(String(us).utf16)
        guard CTFontGetGlyphsForCharacters(font, &ch, &glyph, ch.count), glyph != 0 else { return nil }
        let icon = isIconScalar(scalar)
        guard let entry = rasterizeCore(glyph: glyph, glyphFont: font, color: color, isIcon: icon) else { return nil }
        if color { colorCache[scalar] = entry } else { grayCache[scalar] = entry }
        return entry
    }

    func rasterize(glyph: CGGlyph, glyphFont: CTFont, color: Bool, isIcon: Bool = false) -> AtlasEntry? {
        rasterizeCore(glyph: glyph, glyphFont: glyphFont, color: color, isIcon: isIcon)
    }

    // True for Nerd Font / Powerline / icon ranges in the Unicode Private Use Areas.
    private func isIconScalar(_ scalar: UInt32) -> Bool {
        return (0xE000...0xF8FF).contains(scalar) ||
               (0xF0000...0xFFFFD).contains(scalar) ||
               (0x100000...0x10FFFD).contains(scalar)
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

    // Scratch buffers for layoutRow — hoisted to avoid per-frame heap allocations
    private var scratchGlyphs: [CGGlyph] = []
    private var scratchAdvances: [CGSize] = []
    private var scratchIndices: [CFIndex] = []

    /// Layout an entire terminal row using CoreText.
    /// - Parameter text: The row string; one Unicode scalar per cell, spaces for empty cells.
    /// - Parameter cellWidth: The nominal pixel width of one cell.
    func layoutRow(text: String, cellWidth: CGFloat) -> [Int: RowGlyph] {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font]
        let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrStr)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]

        // Build UTF-16 offset → column mapping and column → scalar mapping
        var charToCol: [Int: Int] = [:]
        var colToScalar: [Int: UInt32] = [:]
        var utf16Offset = 0
        var col = 0
        for scalar in text.unicodeScalars {
            let utf16len = scalar.utf16.count
            charToCol[utf16Offset] = col
            colToScalar[col] = scalar.value
            if utf16len == 2 {
                charToCol[utf16Offset + 1] = col  // surrogate pair second unit
            }
            utf16Offset += utf16len
            col += 1
        }

        var result: [Int: RowGlyph] = [:]

        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            if scratchGlyphs.count < count { scratchGlyphs = [CGGlyph](repeating: 0, count: count) }
            if scratchAdvances.count < count { scratchAdvances = [CGSize](repeating: .zero, count: count) }
            if scratchIndices.count < count { scratchIndices = [CFIndex](repeating: 0, count: count) }
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &scratchGlyphs)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &scratchAdvances)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &scratchIndices)

            // Get the run's font (for fallback fonts)
            let runFont: CTFont
            if let attrs = CTRunGetAttributes(run) as? [CFString: Any],
               let rf = attrs[kCTFontAttributeName] {
                runFont = (rf as! CTFont)
            } else {
                runFont = font
            }

            for i in 0..<count {
                let glyph = scratchGlyphs[i]
                guard glyph != 0 else { continue }
                let strIdx = Int(scratchIndices[i])
                guard let glyphCol = charToCol[strIdx] else { continue }

                let scalar = colToScalar[glyphCol]
                let isIcon = scalar.map(isIconScalar) ?? false
                let isColor = CTFontCreatePathForGlyph(runFont, glyph, nil) == nil
                // 0x4000_0000 differentiates icon-fit rasterizations from normal ones in the cache,
                // since the same glyph index can produce different bitmaps depending on the transform.
                let cacheKey = UInt32(glyph) | (isColor ? 0x8000_0000 : 0) | (isIcon ? 0x4000_0000 : 0)

                let entry: AtlasEntry
                if isColor {
                    if let e = colorCache[cacheKey] {
                        entry = e
                    } else if let e = rasterize(glyph: glyph, glyphFont: runFont, color: true, isIcon: isIcon) {
                        colorCache[cacheKey] = e; entry = e
                    } else { continue }
                } else {
                    if let e = grayCache[cacheKey] {
                        entry = e
                    } else if let e = rasterize(glyph: glyph, glyphFont: runFont, color: false, isIcon: isIcon) {
                        grayCache[cacheKey] = e; entry = e
                    } else { continue }
                }

                let advW = scratchAdvances[i].width
                let colSpan = max(1, Int(round(advW / cellWidth)))

                result[glyphCol] = RowGlyph(
                    glyphIndex: glyph, isColor: isColor, entry: entry,
                    colSpan: colSpan, xOffset: 0, yOffset: 0
                )
            }
        }

        return result
    }

}
