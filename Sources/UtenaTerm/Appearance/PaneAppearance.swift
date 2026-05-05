import simd

struct PaneAppearance {
    var backgroundColor: SIMD3<Float>
    var backgroundOpacity: Float

    static let `default` = PaneAppearance(
        backgroundColor: SIMD3(0, 0, 0),
        backgroundOpacity: 1.0
    )
}
