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
        grayShelfX = 2 // skip the 1x1 slot
    }

    var solidEntry: AtlasEntry { AtlasEntry(u0: 0, v0: 0, u1: 1/Float(Self.atlasSize), v1: 1/Float(Self.atlasSize), pixelWidth: 1, pixelHeight: 1) }

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
