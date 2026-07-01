import SwiftUI

/// Global visual tokens. Paired with the restrained "single accent color + monochrome rest" style,
/// keeping all four screens consistent in spacing, corner radius, and fill, and toning down the
/// "tool/dashboard" feel.
enum Theme {
    /// Control panel width.
    static let panelWidth: CGFloat = 320
    /// Left label column width for settings rows: aligns the leading edge of controls in paired inline
    /// rows like "pattern / intensity", without truncation across languages.
    static let rowLabelWidth: CGFloat = 76
    /// Common corner radius.
    static let corner: CGFloat = 8
    /// Neutral button/swatch fill (adapts to light/dark, introduces no extra hue).
    static let neutralFill = Color.primary.opacity(0.05)
    /// Neutral foreground (slightly dimmer than pure primary, so it doesn't compete with the accent color).
    static let neutralLabel = Color.primary.opacity(0.82)
}
