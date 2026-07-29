import AppKit
import CodeEditSourceEditor
import CodeEditTextView

/// VS Code's coloured stripe down the line numbers: green where lines were added,
/// yellow where they were changed, and a red wedge where lines were deleted.
///
/// **The gutter is the package's, and it offers nothing to decorate it with.**
/// `TextViewController.gutterView` is internal, `GutterViewDelegate` has one
/// method and it is about width, and `GutterView` draws its background, its
/// selected-line bands and its numbers itself with no per-line hook of any kind.
/// There is no supported seam here, so this takes the same route
/// `ClipFloatingSubviews` already takes for the same reason: a coordinator, the
/// controller it is handed, and a view put where the package will not put one.
///
/// What makes it hold together rather than drift:
///
/// - **The gutter is findable without the private property.** `GutterView` is a
///   `public` class hanging somewhere under the `public` scroll view, so it can be
///   picked out by type — see ``gutterView(in:)`` for where AppKit actually keeps
///   it, which is not where `loadView` appears to put it. That is a type check,
///   not a name or an index, and it fails to nothing.
/// - **Its coordinates are the document's.** The gutter is as tall as the whole
///   file and the package keeps `origin.y` at `textView.frame.origin.y`, so a
///   y inside the gutter *is* a y in the text. Which is why `GutterView` fills its
///   own selected-line bands straight at `line.yPos` — the marker view does the
///   same arithmetic on the same numbers.
/// - **Wrapping and folding are answered by the layout manager, not guessed at.**
///   `textLineForIndex` is public and returns the line's *visible* position, so a
///   wrapped line reports the height of all its fragments and a line inside a
///   collapsed fold reports the fold's row — every marker in a fold stacks onto
///   the one line standing for it, which is what should happen.
/// - **It survives `loadView`.** The whole install runs again on
///   `controllerDidAppear`, which is after the controller has rebuilt its views.
///
/// The marker view sits above the gutter's drawing and below nothing: it is a
/// leading strip three points wide, clear everywhere it has nothing to say, and
/// it returns `nil` from `hitTest` so the folding ribbon on the other edge keeps
/// every mouse event it had.
final class GutterDiffMarkers: TextViewCoordinator, @unchecked Sendable {
    /// Where the changed lines come from, and where they go once loaded.
    private let file: URL
    private let projectRoot: URL?
    private let markerView: GutterDiffMarkerView

    private weak var controller: TextViewController?
    /// Held weakly and re-found on every appearance, rather than captured by the
    /// observers below: a `@Sendable` notification block cannot be handed an
    /// `NSView` without sending it across an isolation boundary, and the gutter is
    /// the controller's to replace in any case.
    private weak var gutter: GutterView?
    private var scrollObserver: (any NSObjectProtocol)?
    private var frameObserver: (any NSObjectProtocol)?
    private var reload: Task<Void, Never>?

    @MainActor
    init(file: URL, projectRoot: URL?) {
        self.file = file
        self.projectRoot = projectRoot
        self.markerView = GutterDiffMarkerView()
    }

    // MARK: - Coordinator

    func prepareCoordinator(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.controller = controller
            refresh()
        }
    }

    func controllerDidAppear(controller: TextViewController) {
        MainActor.assumeIsolated {
            self.controller = controller
            install(in: controller)
        }
    }

    func destroy() {
        MainActor.assumeIsolated {
            reload?.cancel()
            reload = nil
            for observer in [scrollObserver, frameObserver].compactMap({ $0 }) {
                NotificationCenter.default.removeObserver(observer)
            }
            scrollObserver = nil
            frameObserver = nil
            markerView.removeFromSuperview()
            markerView.textView = nil
            gutter = nil
            controller = nil
        }
    }

    /// Asks git again, off the main thread, and debounced: the reasons to recompute
    /// — the file appearing, being written to from outside, being saved — can all
    /// arrive within a few milliseconds of each other, and each one is a process.
    @MainActor
    func refresh() {
        guard let projectRoot else { return }
        reload?.cancel()
        reload = Task { @MainActor [file] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let status = await GitLineStatusLoader.load(file: file, in: projectRoot)
            guard !Task.isCancelled else { return }
            markerView.status = status
        }
    }

    // MARK: - Installing

    @MainActor
    private func install(in controller: TextViewController) {
        guard let scrollView = controller.scrollView,
              let gutter = Self.gutterView(in: scrollView)
        else { return }
        self.gutter = gutter

        markerView.textView = controller.textView
        if markerView.superview !== gutter {
            markerView.removeFromSuperview()
            gutter.addSubview(markerView)
        }
        layoutMarkerView()

        for observer in [scrollObserver, frameObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }

        // The same two the package redraws the gutter on, for the same reasons:
        // the clip view's bounds move when the file is scrolled, and the text
        // view's frame changes when lines are laid out, wrapped or folded. The
        // frame is re-taken alongside the redraw because the gutter's width grows
        // with the line count and its height with the document.
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutMarkerView() }
        }
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: controller.textView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layoutMarkerView() }
        }
    }

    /// The gutter, wherever AppKit has put it.
    ///
    /// **Not `scrollView.subviews`, which is where it looks like it should be.**
    /// `loadView` attaches it with `addFloatingSubview`, and that does not add
    /// the view to the scroll view: AppKit lifts every floating subview into a
    /// private `_NSScrollViewFloatingSubviewsContainerView` of its own and adds
    /// *that*. So a scan of the direct subviews finds an `NSClipView` and a
    /// container, no `GutterView`, and this whole coordinator quietly installed
    /// nothing — which is exactly how the markers came to be written, shipped,
    /// and never once drawn.
    ///
    /// Searching breadth-first from the scroll view instead, which is immune to
    /// where the container is in the order and to it being renamed or dropped in
    /// a later macOS. The clip view is skipped because the document is the text,
    /// and the gutter is never inside it — that is the one subtree worth being
    /// large.
    @MainActor
    private static func gutterView(in scrollView: NSScrollView) -> GutterView? {
        var queue = scrollView.subviews
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            if let gutter = view as? GutterView { return gutter }
            if view is NSClipView { continue }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Set outright rather than left to an autoresizing mask. The gutter's frame
    /// is assigned in several places for several reasons — width for the line
    /// count, height for the document, origin for the content insets — and taking
    /// its bounds each time is both cheaper to reason about and immune to arriving
    /// before it has a size at all.
    @MainActor
    private func layoutMarkerView() {
        guard let gutter else { return }
        if markerView.frame != gutter.bounds { markerView.frame = gutter.bounds }
        markerView.needsDisplay = true
    }
}

/// The strip itself. Draws nothing but the markers; the numbers underneath are
/// still the gutter's.
private final class GutterDiffMarkerView: NSView {
    /// Matches `GutterView.backgroundEdgeInsets.leading`, which is zero: the
    /// stripe is on the very edge of the pane, where VS Code puts it.
    private static let stripeWidth: CGFloat = 3
    /// A deletion is a gap rather than a line, so it gets a wedge on the boundary
    /// instead of a stripe beside anything.
    private static let wedgeHeight: CGFloat = 4

    var status: GitLineStatus = .none {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    weak var textView: TextView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The gutter counts y downwards from the top of the document, and every
    /// number this view is given comes from there.
    override var isFlipped: Bool { true }

    /// Transparent to the mouse. The folding ribbon is a sibling in this same view
    /// and lives on hover, and the gutter itself sets an arrow cursor over the
    /// whole strip; neither should notice this is here.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !status.isEmpty,
              let textView,
              let layoutManager = textView.layoutManager,
              let context = NSGraphicsContext.current?.cgContext
        else { return }

        // Where to start reading the markers from: the line at the top of what is
        // being drawn. One line earlier, because the first line of a collapsed
        // fold stands for every line inside it, and those have higher indices than
        // the row they are drawn on.
        let topLine = layoutManager.textLineForPosition(max(dirtyRect.minY, 0))?.index ?? 0
        var index = status.firstIndex(atOrAfter: max(0, topLine - 1))

        context.saveGState()
        defer { context.restoreGState() }

        while index < status.markers.count {
            let marker = status.markers[index]
            index += 1
            guard let line = layoutManager.textLineForIndex(marker.line) else { continue }
            if line.yPos >= dirtyRect.maxY { break }
            if line.yPos + line.height + Self.wedgeHeight <= dirtyRect.minY { continue }

            context.setFillColor(color(for: marker.change).cgColor)
            switch marker.change {
            case .added, .modified:
                context.fill(
                    CGRect(x: 0, y: line.yPos, width: Self.stripeWidth, height: line.height).pixelAligned
                )
            case .deleted:
                // A triangle on the boundary, pointing away from the edge, so it
                // reads as something missing between two lines rather than as a
                // short stripe beside one of them.
                let apex = (line.yPos).rounded()
                context.beginPath()
                context.move(to: CGPoint(x: 0, y: apex - Self.wedgeHeight))
                context.addLine(to: CGPoint(x: Self.wedgeHeight, y: apex))
                context.addLine(to: CGPoint(x: 0, y: apex + Self.wedgeHeight))
                context.closePath()
                context.fillPath()
            }
        }
    }

    /// ``GitChangeColors``, the same three the file tree paints a row in. A
    /// stripe beside line 40 and the colour on that file's name in the tree are
    /// one claim about one repository, so they are one colour — read the tree,
    /// open the file, and the marks carry on saying the same thing.
    private func color(for change: GitLineChange) -> NSColor {
        switch change {
        case .added: GitChangeColors.addedNS
        case .modified: GitChangeColors.modifiedNS
        case .deleted: GitChangeColors.deletedNS
        }
    }
}
