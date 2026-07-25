import CoreGraphics

/// Sizes shared by the bars that stack down the centre pane, so they line up
/// with one another instead of each ending wherever its own glyphs happen to.
enum AppMetrics {
    /// Side inset of the window header and of the pull request's summary bar.
    static let barHorizontalPadding: CGFloat = 10

    /// Width of the single control that closes each of those bars — the
    /// navigator toggle up top, the actions menu below. Fixing it is what makes
    /// the two segmented pickers in front of them share a right edge.
    static let barTrailingControlWidth: CGFloat = 22
}
