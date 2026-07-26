import AppKit

/// A scroller that draws nothing and claims no width.
///
/// The app hides every scrollbar, and SwiftUI does that with
/// `.scrollIndicators(.hidden)` at the window root. AppKit scroll views built by
/// hand — the code editor's — need their own answer, and simply clearing
/// `hasVerticalScroller`/`hasHorizontalScroller` also turns off the scroll view's
/// handling of the matching axis. Installing this instead keeps every scroll
/// path working (wheel, trackpad, `scrollRangeToVisible`) with nothing on screen
/// and no reserved strip, even when the system is set to always show scroll bars.
final class HiddenScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override class func scrollerWidth(
        for controlSize: NSControl.ControlSize,
        scrollerStyle: NSScroller.Style
    ) -> CGFloat {
        0
    }

    override func draw(_ dirtyRect: NSRect) {}
}
