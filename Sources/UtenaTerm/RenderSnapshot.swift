import Foundation
import simd
import GhosttyVt

struct CellSnapshot {
    let scalar: Unicode.Scalar
    let fg: SIMD4<Float>
    let bg: SIMD4<Float>?
}

struct RowSnapshot {
    let cells: [CellSnapshot]
    let rowText: String
}

struct ViewportSnapshot {
    let rows: [RowSnapshot]
    let cursor: CursorState?
    let colors: GhosttyRenderStateColors
}

func resolveColor(
    _ color: GhosttyStyleColor,
    colors: GhosttyRenderStateColors,
    fallback: GhosttyColorRgb
) -> GhosttyColorRgb {
    switch color.tag {
    case GHOSTTY_STYLE_COLOR_RGB: return color.value.rgb
    case GHOSTTY_STYLE_COLOR_PALETTE:
        let idx = Int(color.value.palette)
        return withUnsafeBytes(of: colors.palette) { $0.bindMemory(to: GhosttyColorRgb.self)[idx] }
    default: return fallback
    }
}
