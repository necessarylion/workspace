import AppKit

/// The app's own surface colours. Fixed values, not system colours: the two
/// sidebars keep the standard appearance, while the centre pane and the
/// terminal are their own, deliberately flat shade.
enum AppColors {
    /// The centre pane — editor, diff, pull request, dashboard.
    static let viewerHex = 0x28_28_28

    static let viewerBackground = NSColor(rgb: viewerHex)

    /// The terminal is the same surface as everything else the centre pane
    /// shows, not a darker panel inside it: a shell opens in the same place a
    /// file does, and two shades made that one swap look like two panes.
    static let terminalBackground = NSColor(rgb: viewerHex)

    /// The same value in the form ghostty's config file wants.
    static let terminalBackgroundHex = "282828"
}

extension NSColor {
    /// 0xRRGGBB, opaque unless told otherwise. Themes give the current-line
    /// highlight and the indent guides an alpha, since both are meant to sit
    /// over whatever the background is rather than replace it.
    ///
    /// `rgb:` rather than the `hex:` this used to be called, because
    /// CodeEditTextView declares a public `NSColor(hex: Int, alpha: Double)` of
    /// its own — and `CGFloat` *is* `Double` on every Mac this runs on, so the
    /// two were the same function and every call became ambiguous. The label is
    /// ours to change and theirs is not.
    convenience init(rgb: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
