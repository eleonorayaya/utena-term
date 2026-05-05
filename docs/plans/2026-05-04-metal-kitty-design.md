# Metal Rendering + Kitty Graphics Protocol

## Decisions

- **View layer:** `MTKView` (MTKViewDelegate pattern, CVDisplayLink-driven)
- **Glyph rendering:** row-level CoreText layout → dual atlas (grayscale + RGBA color)
- **PNG decode:** Apple ImageIO (`CGImageSourceCreateWithData`)

## Architecture

### New files

| File | Responsibility |
|------|---------------|
| `MetalTerminalView.swift` | `MTKView` subclass + `MTKViewDelegate`; keyboard/mouse/focus/resize (replaces `TerminalView`) |
| `TerminalRenderer.swift` | Metal device, command queue, pipelines, triple-buffered vertex buffer, per-frame draw sequence |
| `GlyphAtlas.swift` | Dual atlas textures, row-level CoreText layout, glyph + ligature cache |
| `KittyTextureCache.swift` | Image ID → `MTLTexture` cache, PNG decode via ImageIO |
| `Shaders.metal` | Vertex + fragment shaders with `mode`-branched fragment |

### Modified files

- `GhosttyBridge.swift` — Kitty storage limit at init, PNG decode callback, `withKittyGraphics(_:)`
- `TerminalPane.swift` — `TerminalView` → `MetalTerminalView`
- `Package.swift` — link MetalKit

### Deleted files

- `TerminalView.swift` — replaced entirely by `MetalTerminalView.swift`

---

## GlyphAtlas

Two `MTLTexture` atlases, both 2048×2048, shelf-packed:

- **Grayscale** (`r8Unorm`) — outline glyphs, icon fonts (Nerd Fonts etc.)
- **Color** (`rgba8Unorm`) — color emoji and other color glyphs

**Color glyph detection:** `CTFontCreatePathForGlyph` returns `nil` for color glyphs.

**Per-row layout:** each dirty row is processed as a `CTLine` from a `CFAttributedString`.
Walking `CTRun`s gives glyphs with their character mappings. Glyph advance / cellWidth
determines column span:

- Single-cell → cache key `UInt32` (scalar)
- Multi-cell ligature → cache key `String` (source characters, e.g. `"->"`)

Atlas entries store a UV rect; ligature entries are `n * cellWidth` wide.
Row layout is keyed on `(text string, style hash)` for dirty tracking.

---

## TerminalRenderer

### Vertex format

```metal
struct Vertex {
    float2 position;  // NDC
    float2 uv;        // texture coords
    float4 color;     // fg tint (ignored for image quads)
    uint   mode;      // 0=grayscale glyph, 1=color glyph, 2=kitty image
};
```

### Per-frame sequence

1. `bridge.updateRenderState()`
2. Emit Kitty `BELOW_BG` image quads
3. Emit cell background quads (non-default bg only)
4. Emit Kitty `BELOW_TEXT` image quads
5. Walk rows → emit glyph quads (rasterize new glyphs into atlas on demand)
6. Emit cursor quad
7. Emit Kitty `ABOVE_TEXT` image quads
8. Single render pass with all quads → present drawable

Triple-buffered `MTLBuffer` + semaphore prevents CPU/GPU races (max 2 frames in flight).

---

## KittyTextureCache

`[UInt32: MTLTexture]` keyed on Kitty image ID.

**Upload on first reference:**
1. `ghostty_kitty_graphics_image()` → image handle
2. Read width, height, format, data pointer via `ghostty_kitty_graphics_image_get`
3. PNG format → decode via `CGImageSourceCreateWithData` → raw RGBA pixels
4. Create `MTLTexture`, upload with `texture.replace(region:...)`

**Eviction:** if `ghostty_kitty_graphics_image()` returns nil for a cached ID, drop the texture.

**Per-frame placement iteration:** `ghostty_kitty_graphics_placement_render_info` returns
viewport position, pixel size, and source rect in one call. Emit one image quad per visible
placement with UV rect clipped to source rectangle.

---

## GhosttyBridge additions

```swift
// At terminal init:
// ghostty_terminal_setopt(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &limit)
// ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, decodePNGCallback)

func withKittyGraphics(_ body: (GhosttyKittyGraphics) -> Void)
```

PNG decode callback: receives compressed bytes, decodes via ImageIO, writes raw pixels
to the output buffer ghostty-vt provides.
