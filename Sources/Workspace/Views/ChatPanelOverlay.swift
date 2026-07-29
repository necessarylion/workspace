import AppKit
import SwiftUI

/// The floating conversations, drawn over the three panes.
///
/// They are views in this window and not windows of their own, which is the
/// whole point: a panel is clipped to the window, moves with it, and cannot be
/// left behind on another Space or hidden under the app it is about. The cost is
/// that everything a window manager would have done — placing, dragging,
/// resizing, stacking — is done here instead.
///
/// The overlay itself draws nothing and therefore catches nothing: a click that
/// lands anywhere but on a panel goes straight through to the pane underneath.
///
/// Every conversation is drawn — see ``WorkspaceStore/visibleChats`` — but a
/// folded one is drawn twice over: the panel itself stays here, cropped to
/// nothing, so that its terminal is never taken out of the window, and the bar
/// standing for it is one of ``ChatDockStrip``'s.
struct ChatPanelOverlay: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        GeometryReader { geometry in
            let panels = store.visibleChats
            let front = panels.filter { !$0.isCollapsed }.max { $0.depth < $1.depth }

            ZStack(alignment: .topLeading) {
                ForEach(panels) { panel in
                    ChatPanelView(
                        panel: panel,
                        frame: store.chatPanelFrame(of: panel),
                        bounds: geometry.size,
                        isFront: panel === front
                    )
                    // Which panel is in front is a number on the panel, not its
                    // place in the array: reordering the array would move the
                    // terminal's `NSView` inside the view hierarchy, and a view
                    // pulled out and put back loses the keyboard in the middle
                    // of whatever was being typed into it.
                    .zIndex(Double(panel.depth))
                    // A panel arrives and leaves by fading in place rather than
                    // flying in from anywhere: it is opened at a corner it was
                    // opened at last time, and travel across the window would
                    // say the corner meant something.
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }

                // **Under the panels.** The dock is where conversations are put
                // *away*, and a strip of them riding over the one being read
                // covers the bottom of it — the prompt line, which is the part
                // of a terminal a person is actually looking at.
                //
                // Nothing is stranded by that. A bar behind a panel is still
                // reachable: move the panel, fold it, or take the conversation
                // from the Claude list, which lists every live one. A prompt
                // hidden under a row of folded chats has no such way out.
                ChatDockStrip(region: store.chatDockRegion)
                    .zIndex(-1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                WindowClickMonitor(
                    // Open panels only. A folded one has no rectangle to name —
                    // its bar is on a strip that scrolls — and it needs none:
                    // nothing there swallows a click the way a live terminal
                    // does, so the strip's own gestures are enough, and the tap
                    // that brings one back is what focuses it.
                    panels: panels
                        .filter { !$0.isCollapsed }
                        .map { ($0, store.chatPanelFrame(of: $0).onScreenRect) }
                ) { store.raiseChatPanel($0) }
            )
            // The window's size, which is what a *floating* panel is placed and
            // clamped against — one is dragged by hand, and a window-like thing
            // you may not drop where you like is not one. A folded panel is held
            // to the centre pane instead; that rectangle reaches the store from
            // `ContentView`, in this same coordinate space.
            //
            // Read here rather than measured in the store, which has no window
            // to ask.
            .onAppear { store.chatPanelsDidLayout(in: geometry.size) }
            .onChange(of: geometry.size) { _, size in store.chatPanelsDidLayout(in: size) }
        }
    }
}

/// The dock: every folded conversation as a bar, in one row along the bottom of
/// the centre pane, scrolling sideways once there are more of them than the pane
/// is wide.
///
/// **The strip owns the layout, and that is the choice.** A folded bar used to
/// be a rectangle like any other — placed by the app, then draggable to any x on
/// the dock, which it remembered. That cannot survive scrolling: an absolute
/// position inside something that scrolls names a point that has moved by the
/// time it is read, and "past the end" is meaningless when the end is wherever
/// the strip has been scrolled to. So a bar has no position of its own any more,
/// only a **place in the row**, and dragging one moves it in the row rather than
/// putting it somewhere. The other way round — free positions on a canvas as
/// wide as the rightmost bar — keeps a gesture nobody asked for at the price of
/// the thing they did: "scroll until you find it" and "keep it where I put it"
/// are two answers to the same question, and only one of them is reachable.
///
/// It is one row and never two. Bars narrow towards
/// ``ChatPanelFrame/dockedMinimumWidth`` while that is all it takes to fit, and
/// past that the strip scrolls: no bar is ever squeezed past the point where the
/// repository's name — the half that has to survive, since the dock is shared by
/// every repository — stops being readable.
///
/// **It is only as wide as its bars.** The overlay passes clicks through to the
/// panes underneath, and a scroll view spanning the pane would be a full-width
/// strip of window taking every click aimed at the code below it.
struct ChatDockStrip: View {
    /// The centre pane, which the dock runs along the bottom of.
    let region: CGRect

    @Environment(WorkspaceStore.self) private var store

    /// The bar being dragged along the row and how far it has come. Empty the
    /// rest of the time — the row is the store's order until a drag ends.
    @State private var dragging: UUID?
    @State private var travel: CGFloat = 0

    /// Room around the bars for their shadows, which the scroll view would
    /// otherwise crop to a hard line — and a single folded conversation has to
    /// look exactly as it did when it was a rectangle of its own. Kept small:
    /// it is scroll view like the rest, so it is a click the pane does not get,
    /// and it lies right against the bars.
    private static let breathing: CGFloat = 6

    /// The gap the row keeps off its resting end, and gives up the moment it is
    /// scrolled. Small on purpose: it is there so the newest bar is not touching
    /// the edge, not to hold the row away from it.
    private static let resting: CGFloat = 5

    var body: some View {
        let bars = store.dockedChats
        if !bars.isEmpty {
            let width = store.chatDockBarWidth
            let step = width + ChatPanelFrame.dockedGap
            let row = row(bars, step: step)
            let content = CGFloat(bars.count) * step - ChatPanelFrame.dockedGap + Self.resting * 2
            // The whole pane, edge to edge. The dock does not keep the margin
            // the floating panels do: a panel is an object sitting *in* the
            // window and wants air around it, while the dock is a rail along the
            // bottom of it — held off both ends, the row reads as a short strip
            // that happens to be cut, rather than one running out under the pane.
            let room = max(region.width, 0)
            // **The strip is the pane, and the row is what overflows it.**
            //
            // It used to be cut to two and a half bars' worth and anchored to the
            // right, on the theory that a bar sliced down the middle is what says
            // the row carries on. It does — but a strip narrower than the pane
            // leaves the difference as dead space beside it, and moving the strip
            // only moves the dead space: flush right, all of it piles up on the
            // left. Sized to the pane, there is nowhere for it to be.
            //
            // What makes the cut is now the bars themselves, which are sized so
            // that ``ChatPanelFrame/dockedBarsShown`` of them is what a pane
            // holds — so the row overruns the edge rather than stopping short
            // of it.
            let strip = min(content, room)

            ScrollView(.horizontal) {
                HStack(spacing: ChatPanelFrame.dockedGap) {
                    ForEach(row.bars) { panel in
                        ChatDockBar(
                            panel: panel,
                            width: width,
                            onDrag: { translation in
                                dragging = panel.id
                                travel = translation
                            },
                            onDrop: {
                                if row.target >= 0 { store.moveDockedChat(panel, to: row.target) }
                                // Eased, unlike every frame before it: the bar
                                // has been under the pointer and is now let go,
                                // and settling into the slot is the one part of
                                // the drag that is the app's movement and not
                                // the hand's.
                                withAnimation(WorkspaceStore.chatPanelMotion) {
                                    dragging = nil
                                    travel = 0
                                }
                            }
                        )
                        .offset(x: panel.id == dragging ? row.residual : 0)
                        .zIndex(panel.id == dragging ? 1 : 0)
                        // A bar arrives and leaves the way the fold does, so the
                        // panel shrinking away and the bar appearing read as one
                        // movement rather than two things that happened at once.
                        //
                        // This was briefly instant on arrival, while the pause
                        // before a fold was still being blamed on the fade. It
                        // was never the fade — see ``WorkspaceStore/raiseChatPanel(_:)``.
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                // Vertical only. Inset sideways as well, the bars stood in from
                // the strip's ends — so a bar scrolled half out of view was cut
                // short of the edge with a gap beyond it, which reads as a bar
                // that has been *cropped* rather than one that carries on past
                // the edge. Flush, the cut lands on the edge itself and the row
                // reads as going in under it.
                .padding(.vertical, Self.breathing)
                // The bar at each end of the row stands off the edge by this
                // much, and nothing in between does. It is part of the content
                // rather than of the strip, so it travels with it: scrolled, the
                // bars run out under the pane's edge with nothing held open
                // behind them, and the gap reappears at whichever end the row
                // has come to rest against.
                .padding(.horizontal, Self.resting)
                // The row closing over the gap a dragged bar has left, which is
                // the only thing saying the drag is a reordering. The bar itself
                // is under the pointer and must not be animated with it.
                .animation(WorkspaceStore.chatPanelMotion, value: row.target)
            }
            // No scroller. One or two conversations folded away is the ordinary
            // case and has to look exactly as it did before there was a strip —
            // and an overlay scroller across a 30pt row would sit on the bars it
            // is meant to be about. What says there is more is the bar cut off
            // at the edge, which is what a row of them cut off always says.
            .scrollIndicators(.hidden)
            // Zeroed explicitly. A `ScrollView` insets its own content by
            // default on macOS, and that inset is not a padding this file put
            // there — it survived every horizontal padding being taken out, and
            // it is what still held the bars off both ends of the strip.
            .contentMargins(.horizontal, 0, for: .scrollContent)
            // Anchored to the right, so a conversation just folded is on screen
            // rather than off the end, and the bars that scroll out of reach are
            // the ones folded longest ago.
            .defaultScrollAnchor(.trailing)
            // Nothing to scroll, nothing to bounce: a strip that rubber-bands
            // with two bars on it would be a strip announcing itself.
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: strip, height: ChatPanelFrame.titleBarHeight + Self.breathing * 2)
            // Right-hand end first, which is where the dock has always started
            // filling from — and flush with the pane's edge, so the row runs out
            // under it instead of stopping short of it.
            .offset(
                x: max(region.maxX - strip, 0),
                y: ChatPanelFrame.dockLine(in: region) - Self.breathing
            )
        }
    }

    /// The row as it stands mid-drag: the dragged bar already moved to the place
    /// it would land in, and the distance it still has to be offset by to stay
    /// under the pointer. `target` is -1 when nothing is being dragged.
    private func row(_ bars: [ChatPanel], step: CGFloat) -> (bars: [ChatPanel], target: Int, residual: CGFloat) {
        guard step > 0,
              let dragging,
              let from = bars.firstIndex(where: { $0.id == dragging })
        else { return (bars, -1, 0) }
        let target = min(max(from + Int((travel / step).rounded()), 0), bars.count - 1)
        var moved = bars
        moved.insert(moved.remove(at: from), at: target)
        return (moved, target, travel - CGFloat(target - from) * step)
    }
}

/// One folded conversation, as it sits on the dock.
///
/// The same bar the panel wears open — see ``ChatPanelBarContent`` — with the
/// panel's own chrome around it, so that folding reads as the panel *becoming*
/// this. There is no terminal in it: the conversation's surface never leaves the
/// panel it belongs to, which is both why it costs nothing to have twenty of
/// these and why unfolding one is instant.
private struct ChatDockBar: View {
    let panel: ChatPanel
    let width: CGFloat
    let onDrag: (CGFloat) -> Void
    let onDrop: () -> Void

    @Environment(WorkspaceStore.self) private var store

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    var body: some View {
        ChatPanelBarContent(panel: panel)
            .frame(width: width, height: ChatPanelFrame.titleBarHeight)
            .background(Color(nsColor: AppColors.terminalBackground), in: Self.shape)
            .clipShape(Self.shape)
            .overlay(Self.shape.strokeBorder(.white.opacity(0.16)))
            // Tighter than a floating panel's, and deliberately: this one sits
            // *in* the pane rather than over it, and the strip crops whatever
            // reaches past it.
            .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
            .contentShape(Rectangle())
            // A bar on the dock is a button and says so, which the open panel's
            // title bar — a handle you drag by — deliberately does not.
            .pointerCursor()
            // A single click anywhere on it brings the conversation back, so the
            // way up is the whole bar and not just the chevron on the end of it.
            // The drag below asks for a point of travel before it starts, which
            // is what leaves a click a click.
            .onTapGesture { store.unfoldChatPanel(panel) }
            // **`.global`**, for the reason the panel's own title bar is — this
            // view *is* moved by its own drag, both by the offset that keeps it
            // under the pointer and by the row shuffling around it, and a space
            // that moves with the view measures each event against a frame the
            // last one displaced.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { onDrag($0.translation.width) }
                    .onEnded { _ in onDrop() }
            )
    }
}

/// What a click in this window means: which conversation comes to the front,
/// and where the keyboard goes.
///
/// A click on the title bar is a gesture this app owns and could act on
/// directly; a click **in the terminal** is not — `GhosttySurfaceView` answers
/// `mouseDown` itself, takes the keyboard and passes nothing on, so no SwiftUI
/// gesture above it ever fires. Watching the window's mouse-downs is the only
/// way the panel underneath can be brought forward by clicking the part of it
/// you can see. Nothing is ever swallowed: the event carries on to the terminal
/// exactly as it would have.
///
/// **Focus is settled here too, and in one place on purpose.** Raising a panel
/// and putting the cursor in it are the same click and the same hit test, and
/// two monitors both reaching for first responder in the same turn of the
/// runloop would be a race whose loser is whatever the user just clicked. So
/// this one answers for the whole window rather than only for the overlay it is
/// attached to: it is what releases the keys from the **centre pane's** terminal
/// as well, when a click lands on the dashboard or a file or a repository.
/// ``TerminalFocus`` has the moves; this has the policy.
private struct WindowClickMonitor: NSViewRepresentable {
    /// Each panel with the rectangle it is drawn in — which is its own frame, or
    /// its bar on the dock when it is folded away.
    let panels: [(panel: ChatPanel, rect: CGRect)]
    let raise: (ChatPanel) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = MonitorView()
        view.panels = panels
        view.raise = raise
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? MonitorView else { return }
        view.panels = panels
        view.raise = raise
    }

    /// Flipped, so a point converted into it is already in the top-left
    /// coordinates the panels' frames are written in.
    private final class MonitorView: NSView {
        var panels: [(panel: ChatPanel, rect: CGRect)] = []
        var raise: (ChatPanel) -> Void = { _ in }

        override var isFlipped: Bool { true }

        /// Invisible to the mouse, not merely transparent. An `NSView` answers
        /// `hitTest` for every point inside it whether it drew anything there or
        /// not, and this one covers the whole window: without this, laying the
        /// overlay over the panes would take every click in the app.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// `nonisolated` only so `deinit` can hand it back; everything else that
        /// touches it is on the main actor, where an `NSView` lives.
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
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                self?.settle(event)
                return event
            }
        }

        private func stopWatching() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        /// One click, three answers.
        ///
        /// There is no `panels.count > 1` short cut out here any more, and there
        /// cannot be: releasing the keyboard has to work with one conversation
        /// open and with none at all. Raising is still free in that case —
        /// ``WorkspaceStore/raiseChatPanel(_:)`` is a no-op for a panel already
        /// in front, which is the guard that comment is about.
        private func settle(_ event: NSEvent) {
            // One monitor sees every window's clicks; Settings and any sheet are
            // somebody else's business.
            guard let window, event.window === window else { return }
            let terminal = TerminalFocus.surface(under: event.locationInWindow, in: window)
            let point = convert(event.locationInWindow, from: nil)
            // Front to back, so a click where two panels overlap raises the one
            // that was actually clicked rather than the one behind it.
            let hit = panels
                .sorted(by: { $0.panel.depth > $1.panel.depth })
                .first(where: { $0.rect.contains(point) })

            if let hit {
                raise(hit.panel)
                // The conversation itself needs nothing from us — the surface
                // takes the keyboard in its own `mouseDown`. The rest of the
                // panel is what had no answer: its title bar, its edges, the gap
                // beside its buttons. Clicking any of those is still a person
                // saying which conversation they are in.
                if terminal == nil { TerminalFocus.give(to: hit.panel.session) }
            } else if terminal == nil {
                // Nowhere near a terminal, and something else is about to be
                // clicked. Whether that leaves the keys anywhere is its own
                // business; what matters is that they stop going to Claude.
                TerminalFocus.release(in: window)
            }
        }
    }
}
