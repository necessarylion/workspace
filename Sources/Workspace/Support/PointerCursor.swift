import AppKit
import SwiftUI

extension View {
    /// Shows the pointing-hand cursor while the pointer is over this view.
    ///
    /// AppKit keeps the arrow cursor over buttons; this app is shaped like a
    /// browser, so anything clickable should say so the way a link does.
    /// Pass `false` for a control that is currently disabled.
    func pointerCursor(_ enabled: Bool = true) -> some View {
        modifier(PointerCursorModifier(enabled: enabled))
    }
}

private struct PointerCursorModifier: ViewModifier {
    let enabled: Bool

    /// Tracked so the push below is always balanced by exactly one pop, even
    /// if the view goes away while the pointer is still inside it.
    @State private var isInside = false

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(enabled ? .link : nil)
        } else {
            content
                .onHover { inside in
                    let wanted = inside && enabled
                    guard wanted != isInside else { return }
                    isInside = wanted
                    if wanted {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onDisappear {
                    guard isInside else { return }
                    isInside = false
                    NSCursor.pop()
                }
        }
    }
}
