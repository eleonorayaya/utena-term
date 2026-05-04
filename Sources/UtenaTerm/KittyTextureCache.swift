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
        // Check eviction if cached
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

        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, &dataPtr)
        _ = ghostty_kitty_graphics_image_get(image, GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &dataLen)

        guard let pixels = dataPtr, width > 0, height > 0 else { return nil }

        switch format {
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGBA:
            return makeAndCache(
                imageID: imageID,
                bytes: UnsafeRawPointer(pixels),
                width: Int(width), height: Int(height),
                format: .rgba8Unorm, bytesPerRow: Int(width) * 4
            )
        case GHOSTTY_KITTY_IMAGE_FORMAT_RGB:
            let expanded = expandRGBtoRGBA(pixels, count: Int(width * height))
            return expanded.withUnsafeBytes { raw in
                makeAndCache(
                    imageID: imageID,
                    bytes: raw.baseAddress!,
                    width: Int(width), height: Int(height),
                    format: .rgba8Unorm, bytesPerRow: Int(width) * 4
                )
            }
        default:
            return nil
        }
    }

    private func makeAndCache(
        imageID: UInt32,
        bytes: UnsafeRawPointer,
        width: Int, height: Int,
        format: MTLPixelFormat, bytesPerRow: Int
    ) -> MTLTexture? {
        let td = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        td.usage = .shaderRead
        td.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: td) else { return nil }
        tex.replace(
            region: MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                              size: MTLSize(width: width, height: height, depth: 1)),
            mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow
        )
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
