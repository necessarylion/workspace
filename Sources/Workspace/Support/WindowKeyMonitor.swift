import AppKit
import SwiftUI

extension View {
    /// Watches this view's window for `mask` events, ahead of both the
    /// responder chain and the menu bar. Return true from `handler` to swallow
    /// one, false to let it carry on as usual.
    ///
    /// Neither of the ordinary routes reaches the keys this app needs.
    /// `GhosttySurfaceView` answers `keyDown` itself and passes nothing on, so
    /// a shortcut owned by a view never fires while the terminal has focus; and
    /// a SwiftUI `keyboardShortcut` becomes a menu key equivalent, which is the
    /// opposite problem — it fires even while a sheet or a text field has the
    /// keyboard. A monitor sits in front of both and decides for itself.
    ///
    /// `mask` is read once, when the view first lands in a window.
    func onWindowKeyEvent(
        matching mask: NSEvent.EventTypeMask = .keyDown,
        perform handler: @escaping (NSEvent, NSWindow) -> Bool
    ) -> some View {
        background(WindowKeyMonitor(mask: mask, handler: handler).frame(width: 0, height: 0))
    }
}

private struct WindowKeyMonitor: NSViewRepresentable {
    let mask: NSEvent.EventTypeMask
    let handler: (NSEvent, NSWindow) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.mask = mask
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? MonitorView)?.handler = handler
    }
}

/// Zero-sized, and there only for its window: one monitor sees every window's
/// events, so it has to know which window the key was meant for. Settings, and
/// anything else the app puts up, are then somebody else's business.
private final class MonitorView: NSView {
    var mask: NSEvent.EventTypeMask = .keyDown
    var handler: (NSEvent, NSWindow) -> Bool = { _, _ in false }

    /// `nonisolated` only so `deinit` can hand it back. Everything else that
    /// touches it is on the main actor, which is where an `NSView` lives.
    private nonisolated(unsafe) var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopWatching()
        } else {
            startWatching()
        }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func startWatching() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self,
                  let window = self.window,
                  Self.belongs(event, to: window),
                  self.handler(event, window)
            else { return event }
            return nil
        }
    }

    private func stopWatching() {
        guard let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    /// A key event names the window it was typed into. A modifier going up or
    /// down often names none, and then the key window is the one that meant it.
    private static func belongs(_ event: NSEvent, to window: NSWindow) -> Bool {
        if let target = event.window { return target === window }
        return window.isKeyWindow
    }
}
