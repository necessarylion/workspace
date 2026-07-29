import AppKit
import SwiftUI

/// One floating conversation: a title bar to move it by, the real terminal
/// running `claude` underneath, and eight edges to size it from.
///
/// Dragging and resizing are held **in this view** until the mouse comes up, and
/// only then written to the store. The store is what the whole window is drawn
/// from, so putting sixty position changes a second through it would redraw
/// every pane to move one rectangle; kept here, the redraw is the panel alone.
///
/// **It stays in the window when it is folded**, cropped to nothing at the foot
/// of the dock. What the user sees of a folded conversation is its bar on
/// ``ChatDockStrip``; what stays here is the terminal, mounted and at the size
/// it will come back at. That is the whole of why unfolding is instant — a
/// surface taken out of the window has to be re-added, re-scaled and redrawn
/// before there is anything to read, and that wait was the lag folding used to
/// have on both ends.
struct ChatPanelView: View {
    let panel: ChatPanel
    /// Where the store says this panel goes: its own place, or the line at the
    /// foot of the dock it folds away into.
    let frame: ChatPanelFrame
    /// The window the panel is clamped inside, from the overlay's geometry.
    let bounds: CGSize
    /// Whether this is the panel in front, which is all the shadow says.
    let isFront: Bool

    @Environment(WorkspaceStore.self) private var store

    /// How far the title bar has been dragged since the mouse went down, which
    /// edges a resize is pulling and how far. All three are empty the rest of
    /// the time.
    @State private var drag = CGSize.zero
    @State private var resizing: ChatPanelEdges = []
    @State private var stretch = CGSize.zero

    private static let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

    /// The reach of the resize bands. Statics rather than locals because the
    /// title bar has to know them too — the top band and both top corners fall
    /// inside it, and a bar that went on answering drags there would take all
    /// three for itself. See ``ChatPanelBarHandle``.
    private static let edgeThickness: CGFloat = 6
    private static let edgeCorner: CGFloat = 14

    var body: some View {
        let live = self.live
        // **The size the terminal is laid out at, and it is never the panel's.**
        // A `GhosttySurfaceView` reflows its grid on every size it is handed, so
        // a panel animating open or shut would otherwise hand it sixty of them
        // on the way — the transcript rewrapping all the way up, `claude`
        // redrawing its boxed prompt over and over — and a folded one would be
        // squeezed to a 300pt bar and back.
        //
        // Pinned to the panel's *unfolded* geometry, the surface is handed one
        // size and keeps it through fold, unfold and drag alike; the panel's own
        // frame is what animates, and `clipShape` crops the terminal as it goes.
        // A real resize is the one thing that must track the pointer, so that
        // one drag reads `live` instead.
        let steady = resizing.isEmpty ? panel.frame : live

        VStack(alignment: .leading, spacing: 0) {
            titleBar
                // Its own width, not the stack's. The terminal below is the
                // widest thing here and a folded panel is narrower than both, so
                // without this the bar would be laid out at the terminal's width
                // and the crop would take its buttons off the right-hand end.
                .frame(width: live.width)
            Divider()
            terminal
                .frame(
                    width: steady.width,
                    height: max(steady.height - ChatPanelFrame.titleBarHeight - 1, 0)
                )
        }
        // Top-**leading**, so a panel narrower than its terminal crops from the
        // right and the bottom rather than recentring the conversation.
        .frame(width: live.width, height: live.visibleHeight, alignment: .topLeading)
        .background(Color(nsColor: AppColors.terminalBackground), in: Self.shape)
        .clipShape(Self.shape)
        .overlay(Self.shape.strokeBorder(.white.opacity(0.16)))
        // Deep enough to read as floating over the panes rather than sitting in
        // one of them, which is the only thing telling the user it can be moved.
        // The panel in front is lifted a little further, which is what says
        // which of two overlapping conversations the keys are going into.
        .shadow(
            color: .black.opacity(isFront ? 0.45 : 0.3),
            radius: isFront ? 20 : 12,
            y: isFront ? 8 : 4
        )
        // Outside the clip, so the bands sit on the panel's own edges rather
        // than being rounded off with its corners.
        .overlay {
            if !panel.isCollapsed { resizeEdges }
        }
        // Folded, the panel is still here and still holding a terminal, and a
        // terminal is an `NSView` that answers a mouse whether anything drew it
        // or not. Nothing about a folded conversation is clickable: its bar on
        // the strip is, and the pane underneath is.
        .allowsHitTesting(!panel.isCollapsed)
        .offset(x: live.x, y: live.y)
    }

    /// Where the panel is right now: what the store says, plus whatever drag or
    /// pull is in progress, kept inside the window at every step so it stops at
    /// the edge rather than following the pointer out of it.
    ///
    /// A folded panel is neither moved nor sized here. It is cropped to nothing
    /// at the foot of the dock, and the bar that stands for it is the strip's —
    /// which is also where dragging one goes, since what a drag on the strip
    /// means is an order and not a place.
    private var live: ChatPanelFrame {
        guard !panel.isCollapsed else { return frame }
        if !resizing.isEmpty {
            return frame.resized(pulling: resizing, by: stretch, in: bounds).clamped(to: bounds)
        }
        var result = frame
        result.x += drag.width
        result.y += drag.height
        return result.clamped(to: bounds)
    }

    // MARK: - Title bar

    private var titleBar: some View {
        ChatPanelBarContent(panel: panel)
            // The whole bar is the handle, gaps included — everything the resize
            // bands above it do not already own. See ``ChatPanelBarHandle`` for
            // why that exception exists.
            .contentShape(ChatPanelBarHandle(band: Self.edgeThickness, corner: Self.edgeCorner))
            // **No double-click to fold, and that is what makes the two buttons
            // answer at once.** A `count: 2` tap on the bar cannot be recognised
            // until a second click has failed to arrive, so *every* single click
            // inside it — including the ones on the fold and close buttons,
            // which are its children — was held for the double-click interval
            // before it could fire. That wait was the delay: the buttons were
            // never slow, they were not allowed to act yet. Double-clicking was
            // the one thing that felt instant, because it was the gesture
            // everything else was waiting for.
            // **`.global`, and it has to be.** The default space is `.local`,
            // which is the dragged view's own — and this view is moved by the
            // drag, through the `.offset` at the end of `body`. Each event would
            // then be measured against a frame the previous event had already
            // moved, so the panel chased its own translation back and forth
            // under the pointer instead of following it. A space that does not
            // move with the panel is the whole fix; the window is as good as the
            // screen here, since the offset is a delta either way.
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if drag == .zero { store.raiseChatPanel(panel) }
                        drag = value.translation
                    }
                    .onEnded { _ in
                        defer { drag = .zero }
                        store.placeChatPanel(panel, frame: live)
                    }
            )
    }

    // MARK: - The conversation

    @ViewBuilder
    private var terminal: some View {
        ZStack {
            // The panel's own background, so what a growing panel shows before
            // the terminal lands is the terminal's colour rather than a hole.
            Color(nsColor: AppColors.terminalBackground)

            TerminalPaneView(session: panel.session)
                .padding(.top, 6)
                .padding(.leading, 6)
                // The `NSView` belongs to the session and cannot be swapped
                // in `updateNSView`, so it gets the session's identity.
                .id(panel.session.id)

            if panel.session.isStartingClaude {
                // Same cover the Claude tab puts up, and for the same reason:
                // what is behind it is a shell prompt being typed into by the
                // app, which reads as a glitch.
                VStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Starting Claude Code…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: AppColors.terminalBackground))
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: panel.session.isStartingClaude)
    }


    // MARK: - Resizing

    /// The eight places a window is sized from, as bands laid over the panel's
    /// own edges. Narrow enough that the terminal keeps every click a person
    /// aims at the terminal, wide enough to find without looking — the corners
    /// get more, because a corner is what you reach for when you want both.
    private var resizeEdges: some View {
        let thickness = Self.edgeThickness
        let corner = Self.edgeCorner

        return Color.clear
            // The band under the pointer is what answers a click here; the
            // panel itself must go on being invisible to the mouse everywhere
            // else, or it would take the terminal's every click.
            .allowsHitTesting(false)
            .overlay(alignment: .top) { band(.top).frame(height: thickness) }
            .overlay(alignment: .bottom) { band(.bottom).frame(height: thickness) }
            .overlay(alignment: .leading) { band(.leading).frame(width: thickness) }
            .overlay(alignment: .trailing) { band(.trailing).frame(width: thickness) }
            .overlay(alignment: .topLeading) { band([.top, .leading]).frame(width: corner, height: corner) }
            .overlay(alignment: .topTrailing) { band([.top, .trailing]).frame(width: corner, height: corner) }
            .overlay(alignment: .bottomLeading) { band([.bottom, .leading]).frame(width: corner, height: corner) }
            .overlay(alignment: .bottomTrailing) { grip.frame(width: corner, height: corner) }
    }

    private func band(_ edges: ChatPanelEdges) -> some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .gesture(resizeGesture(edges))
            .resizePointer(edges)
    }

    /// `.global` for the same reason the title bar's drag is — see there. A pull
    /// on the top or left edge moves the panel's origin as well as its size, so
    /// these bands are carried by their own gesture just as surely.
    private func resizeGesture(_ edges: ChatPanelEdges) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if resizing.isEmpty { store.raiseChatPanel(panel) }
                resizing = edges
                stretch = value.translation
            }
            .onEnded { _ in
                store.placeChatPanel(panel, frame: live)
                resizing = []
                stretch = .zero
            }
    }

    /// The bottom-right corner, drawn as well as felt. Every edge sizes the
    /// panel now, but this is the corner with room to pull into — the panel
    /// lives in the bottom-right of the window — and three diagonal strokes are
    /// still the only thing on screen that says "sizeable" without being
    /// hovered first.
    private var grip: some View {
        band([.bottom, .trailing])
            .overlay {
                ChatPanelGrip()
                    .frame(width: 11, height: 11)
                    .padding(1.5)
                    .allowsHitTesting(false)
            }
    }
}

/// What is written on a conversation's bar, wherever that bar is: the mark, the
/// name, and the two buttons.
///
/// One view for both because they are one thing — a folded conversation's bar on
/// the dock *is* the title bar of the panel it came from, and the fold reads as
/// the panel becoming that bar. What differs is only what a click on it means,
/// so the gestures stay outside: ``ChatPanelView`` puts a drag and the resize
/// bands' exception on it, ``ChatDockStrip`` a click that brings the panel back.
struct ChatPanelBarContent: View {
    let panel: ChatPanel

    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        HStack(spacing: 7) {
            // Claude's own mark — the one the navigator's Claude tab, the
            // dashboard button and the sidebar's badge all wear — rather than
            // the generic sparkles every app now draws for "AI".
            ChatPanelMark(isWorking: panel.session.isWorking)

            // One line, repository first: `workspace | fix the scroll bug`.
            // Stacked, the two competed for a 30pt bar and the conversation —
            // the half that actually changes — got the smaller type.
            //
            // **The repository holds its width and the conversation gives way**,
            // which is the same argument `dockedMinimumWidth` is written from:
            // the dock is shared by every repository, so the project is what a
            // folded bar must still be saying when there is no room left. Both
            // are capped at one line, so a long conversation title ends in an
            // ellipsis rather than pushing the buttons off the end of the bar.
            HStack(spacing: 5) {
                Text(panel.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text("|")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
                Text(panel.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 4)

            barButton(
                panel.isCollapsed ? "chevron.up" : "chevron.down",
                help: panel.isCollapsed ? "Unfold" : "Fold down to the bottom"
            ) {
                store.toggleChatPanelCollapsed(panel)
            }
            barButton("xmark", help: "End this conversation") {
                store.closeChatPanel(panel)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: ChatPanelFrame.titleBarHeight)
        .background(.ultraThinMaterial)
    }

    private func barButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .pointerCursor()
        .help(help)
    }
}

/// The mark on a conversation's title bar, breathing while a turn is running.
///
/// The tinted symbol this replaced could say "working" by turning the accent
/// colour. The real mark is full-colour artwork and deliberately not a template
/// (see ``ClaudeMark``), so the signal moves to the one thing left: it fades in
/// and out, the same slow breath ``ClaudeWorkingBadge`` gives a repository's
/// card. Two places saying one thing the same way — and no second spinner
/// beside the one the panel already puts up while `claude` starts.
private struct ChatPanelMark: View {
    let isWorking: Bool

    @State private var isDim = false

    var body: some View {
        ClaudeMark(size: 14)
            .opacity(isDim ? 0.35 : 1)
            // The animation is picked when `isDim` changes, so the end of a turn
            // is a short fade back to full strength rather than a breath left
            // running under a conversation that has stopped.
            .animation(
                isWorking
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .easeOut(duration: 0.2),
                value: isDim
            )
            .onAppear { isDim = isWorking }
            .onChange(of: isWorking) { _, working in isDim = working }
            .help(isWorking ? "This conversation is working" : "Claude Code")
    }
}

/// The part of the title bar that is the bar's own — everything the panel's
/// resize bands do not already own.
///
/// The bands are laid over the panel's edges *outside* the clip, so the top one
/// and both top corners land inside the 30 points the title bar occupies. Two
/// drag gestures over one pixel is a coin toss, and this bar was winning it:
/// pulling the top-left corner moved the panel instead of sizing it, while every
/// corner clear of the bar sized it fine. Taking those points out of the bar's
/// own hit shape settles it by leaving nothing to arbitrate.
///
/// A bar on the dock has no bands over it and no exception to make, which is
/// what keeps a single click anywhere on it the way back up.
private struct ChatPanelBarHandle: Shape {
    /// The top band's thickness, and how far into the bar the corners reach.
    var band: CGFloat
    var corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard band > 0 else {
            path.addRect(rect)
            return path
        }
        // Below the corners, the full width; between the band and the corners,
        // whatever the corners leave in the middle.
        path.addRect(CGRect(
            x: rect.minX,
            y: rect.minY + corner,
            width: rect.width,
            height: max(rect.height - corner, 0)
        ))
        path.addRect(CGRect(
            x: rect.minX + corner,
            y: rect.minY + band,
            width: max(rect.width - corner * 2, 0),
            height: max(corner - band, 0)
        ))
        return path
    }
}

/// Three diagonal strokes, the way every resizable corner on the desktop has
/// looked since it was three diagonal strokes on a Mac.
private struct ChatPanelGrip: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for inset in stride(from: size.width, through: size.width / 3, by: -4.5) {
                path.move(to: CGPoint(x: size.width - inset, y: size.height))
                path.addLine(to: CGPoint(x: size.width, y: size.height - inset))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 1.4)
        }
    }
}

private extension View {
    /// The resize cursor for one band, put on the **same** system the rest of
    /// the app's cursors use.
    ///
    /// It used to push an `NSCursor` from `onHover`, and the top edge and both
    /// top corners were dead because of it: those three bands lie inside the
    /// title bar, the bar wears the app's `pointerCursor`, and on macOS 15 that
    /// resolves through `pointerStyle` — a declared region, which AppKit settles
    /// against every other declared region and not against a cursor somebody
    /// pushed by hand. The bar's region won and the pointer stayed an arrow,
    /// while every band clear of the bar worked. Declaring the bands the same
    /// way puts them back in the same argument, which the topmost region wins.
    ///
    /// It also buys the real cursor. There is no public diagonal `NSCursor`, so
    /// the hand-pushed version fell back to a crosshair on all four corners;
    /// `frameResize` names the corner and AppKit draws the proper one.
    @ViewBuilder
    func resizePointer(_ edges: ChatPanelEdges) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.frameResize(position: edges.resizePosition))
        } else {
            onHover { inside in
                if inside {
                    edges.cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}
