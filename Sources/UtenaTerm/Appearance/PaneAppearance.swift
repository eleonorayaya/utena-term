import AppKit
import simd

struct PaneAppearance {
    var backgroundColor: SIMD3<Float>
    var backgroundOpacity: Float

    /// Default pane fill — pulled from the design palette so the terminal
    /// canvas matches the chrome around it.
    static let `default` = PaneAppearance(
        backgroundColor: Palette.simd3(Palette.surfaceBackground),
        backgroundOpacity: 1.0
    )
}
