import AppKit

// Design tokens from docs/design/session-ui/terminal-session-manager.html.
// Naming is functional (textPrimary, statusError, brand) rather than literal
// (white, red, pink) — this keeps call sites readable and lets the palette
// retune without renaming every reference.
//
// Mockup uses oklch(L C H); the inline comments preserve those coordinates
// so the sRGB approximations below can be retuned against the source.
enum Palette {

    // MARK: - Surfaces (background ladder)

    /// App/window background — darkest, no panel above.
    static let surfaceBackground = srgb(0.108, 0.097, 0.140) // oklch(0.20 0.026 320)
    /// Primary panel background (switcher overlay, statusline base).
    static let surfacePrimary    = srgb(0.143, 0.131, 0.176) // oklch(0.24 0.028 320)
    /// Raised secondary surface (rows, cards).
    static let surfaceSecondary  = srgb(0.190, 0.176, 0.226) // oklch(0.29 0.030 320)
    /// Most-raised tertiary surface (kbd chips above panels).
    static let surfaceTertiary   = srgb(0.240, 0.225, 0.278) // oklch(0.34 0.032 320)
    /// Deepest surface — recessed wells, statusline footer accents.
    static let surfaceDeep       = srgb(0.090, 0.080, 0.118) // oklch(0.18 0.020 310)

    // MARK: - Text (foreground ladder)

    /// Primary text — headings, focused row labels.
    static let textPrimary   = srgb(0.953, 0.950, 0.929) // oklch(0.97 0.020 85)
    /// Secondary text — body labels, default row text.
    static let textSecondary = srgb(0.852, 0.842, 0.812) // oklch(0.88 0.025 80)
    /// Tertiary text — supporting metadata, breadcrumbs.
    static let textTertiary  = srgb(0.706, 0.690, 0.658) // oklch(0.74 0.030 70)
    /// Muted text — separators, dim labels.
    static let textMuted     = srgb(0.582, 0.547, 0.604) // oklch(0.60 0.040 330)
    /// Subtle text — keybind glyphs, lowest-emphasis labels.
    static let textSubtle    = srgb(0.438, 0.412, 0.460) // oklch(0.46 0.040 330)

    // MARK: - Brand (accent — pink)

    /// Primary brand color — focus rings, active indicators.
    static let brand        = srgb(0.953, 0.654, 0.792) // oklch(0.84 0.13 345)
    /// Brand dimmed — secondary brand uses, prompt symbols.
    static let brandDim     = srgb(0.866, 0.557, 0.708) // oklch(0.76 0.11 345)
    /// Brand glow — for shadows / soft halos.
    static let brandGlow    = brand.withAlphaComponent(0.18)
    /// Brand-tinted background — focused rows, active window pills.
    static let brandSoft    = brand.withAlphaComponent(0.14)
    /// Brand-tinted background, stronger.
    static let brandStrong  = brand.withAlphaComponent(0.30)
    /// Brand stroke for focused-row borders.
    static let brandBorder  = brand.withAlphaComponent(0.45)

    // MARK: - Status

    /// Success / running / nominal.
    static let statusSuccess = srgb(0.541, 0.910, 0.780) // mint     · oklch(0.86 0.13 165)
    /// Warning / needs attention (soft).
    static let statusWarning = srgb(0.949, 0.808, 0.541) // peach    · oklch(0.88 0.12 80)
    /// Error / needs attention (urgent).
    static let statusError   = srgb(0.972, 0.604, 0.553) // coral    · oklch(0.80 0.15 20)
    /// Informational / waiting.
    static let statusInfo    = srgb(0.737, 0.776, 0.953) // lavender · oklch(0.84 0.10 275)

    // MARK: - Borders

    /// Standard border / hairline divider.
    static let border        = srgb(0.42, 0.40, 0.46, 0.55)
    /// Subtle border / interior divider.
    static let borderSubtle  = srgb(0.42, 0.40, 0.46, 0.26)

    // MARK: - Component fills

    /// Background for inline numbered/index chips.
    static let chipBackground = srgb(0.220, 0.205, 0.245, 0.55) // oklch(0.30 0.015 310 / 0.55)

    // MARK: - Fonts

    /// Body monospace (11pt regular) — default statusline / row text.
    static let monoBody  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// Body monospace, semibold — emphasized labels (session name, branch).
    static let monoBodyBold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    /// Small monospace (10pt) — secondary labels, kbd glyphs.
    static let monoSmall = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    /// Small monospace, semibold — kbd glyphs, numbered chips.
    static let monoSmallBold = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
    /// Tiny monospace (9pt semibold, letterspaced) — section labels.
    static let monoTinyCaps = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)

    // MARK: - Helpers

    private static func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
