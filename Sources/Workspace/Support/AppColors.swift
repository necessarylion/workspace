import AppKit

/// The app's own surface colours. Fixed values, not system colours: the two
/// sidebars keep the standard appearance, while the centre pane and the
/// terminal are their own, deliberately flat shades.
enum AppColors {
    /// The centre pane — editor, diff, pull request, dashboard.
    static let viewerBackground = NSColor(hex: 0x28_28_28)

    /// The terminal, a shade darker so it reads as its own surface.
    static let terminalBackground = NSColor(hex: 0x1E_1E_1E)

    /// The same value in the form ghostty's config file wants.
    static let terminalBackgroundHex = "1e1e1e"
}

extension NSColor {
    /// 0xRRGGBB, opaque.
    convenience init(hex: Int) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
