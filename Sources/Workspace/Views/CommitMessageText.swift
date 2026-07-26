import AppKit
import SwiftUI

/// A commit message, with every `#123` in it drawn as a link to that pull
/// request: blue, underlined while the pointer is on it, and openable.
///
/// It is AppKit rather than a SwiftUI `Text` because of where commit messages
/// live. `Text` can colour a run but cannot say when the pointer is over that
/// run, and most of these messages sit inside a whole-row `Button`, which takes
/// every click before a link inside it can. So the text is laid out here: it
/// hit-tests the reference itself, underlines the one under the pointer, and
/// hands every other click straight back to the row.
struct CommitMessageText: View {
    let text: String
    var font: NSFont = .preferredFont(forTextStyle: .callout)
    var color: NSColor = .labelColor
    var lineLimit: Int = 1
    /// Clicking `#123`.
    var openReference: (Int) -> Void
    /// Clicking anywhere else, so a row keeps its own action.
    var otherClick: (() -> Void)?
    /// The pointer entering or leaving the message, so a row that lights up on
    /// hover stays lit while the pointer crosses the text.
    var hoverChanged: ((Bool) -> Void)?

    var body: some View {
        Representable(
            text: text,
            font: font,
            color: color,
            lineLimit: lineLimit,
            openReference: openReference,
            otherClick: otherClick,
            hoverChanged: hoverChanged
        )
        // A drawn view has no baseline of its own, so it is given the one its
        // first line sits on — otherwise it lands below the `Text` beside it in
        // a `.firstTextBaseline` stack.
        .alignmentGuide(.firstTextBaseline) { _ in LinkedMessageView.baseline(for: font) }
    }

    private struct Representable: NSViewRepresentable {
        let text: String
        let font: NSFont
        let color: NSColor
        let lineLimit: Int
        let openReference: (Int) -> Void
        let otherClick: (() -> Void)?
        let hoverChanged: ((Bool) -> Void)?

        func makeNSView(context: Context) -> LinkedMessageView { LinkedMessageView() }

        func updateNSView(_ view: LinkedMessageView, context: Context) {
            view.openReference = openReference
            view.otherClick = otherClick
            view.hoverChanged = hoverChanged
            view.configure(text: text, font: font, color: color, lineLimit: lineLimit)
        }

        func sizeThatFits(
            _ proposal: ProposedViewSize,
            nsView: LinkedMessageView,
            context: Context
        ) -> CGSize? {
            nsView.size(fitting: proposal.width ?? .greatestFiniteMagnitude)
        }
    }
}

extension NSFont {
    /// The same size at another weight — the AppKit spelling of SwiftUI's
    /// `.callout.weight(.medium)`.
    func weighted(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

/// The text itself: TextKit laying out the message, plus the pointer tracking
/// that makes the references behave like links.
final class LinkedMessageView: NSView {
    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer()

    private var references: [PullRequestReference.Match] = []
    /// Which reference the pointer is on, as an index into `references`.
    private var hovered: Int?
    private var trackingArea: NSTrackingArea?
    private var applied: Configuration?

    var openReference: ((Int) -> Void)?
    var otherClick: (() -> Void)?
    var hoverChanged: ((Bool) -> Void)?

    private struct Configuration: Equatable {
        var text: String
        var font: NSFont
        var color: NSColor
        var lineLimit: Int
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.lineFragmentPadding = 0
        container.lineBreakMode = .byTruncatingTail
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Drawn from the top down, the way SwiftUI places everything else.
    override var isFlipped: Bool { true }

    /// So the first click on a window that is not in front still lands on the
    /// link, rather than only waking the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Content

    func configure(text: String, font: NSFont, color: NSColor, lineLimit: Int) {
        let wanted = Configuration(text: text, font: font, color: color, lineLimit: lineLimit)
        guard applied != wanted else { return }
        applied = wanted

        references = PullRequestReference.matches(in: text)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        for reference in references {
            attributed.addAttribute(.foregroundColor, value: NSColor.linkColor, range: reference.range)
        }
        storage.setAttributedString(attributed)
        container.maximumNumberOfLines = lineLimit

        hovered = nil
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The size the message wants inside the width it is offered.
    ///
    /// A width of zero is the row asking how small this can go rather than a
    /// width to lay out in. The answer has to be "as small as you like" — the
    /// text truncates — or the row reads it as rigid and hands it a slice of
    /// the space instead of everything its neighbours leave over.
    func size(fitting width: CGFloat) -> CGSize {
        let bounded = width.isFinite && width > 0
        let limit = bounded ? width : CGFloat.greatestFiniteMagnitude
        container.size = CGSize(width: limit, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = ceil(used.height)
        guard bounded || width != 0 else { return CGSize(width: 0, height: height) }
        return CGSize(width: ceil(min(used.width, limit)), height: height)
    }

    /// Where the first line's baseline falls from the top of the view — asked of
    /// the same machinery that lays the text out, so it is where the text really
    /// sits rather than a guess from the font's metrics.
    static func baseline(for font: NSFont) -> CGFloat {
        NSLayoutManager().defaultBaselineOffset(for: font)
    }

    override func draw(_ dirtyRect: NSRect) {
        prepareLayout()
        let glyphs = layoutManager.glyphRange(for: container)
        layoutManager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func prepareLayout() {
        let size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        if container.size != size {
            container.size = size
            layoutManager.ensureLayout(for: container)
        }
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Links

    /// The reference drawn under a point, if the point is really on it — the
    /// layout manager answers with the nearest glyph otherwise, which would
    /// make the whole line clickable.
    private func reference(at point: NSPoint) -> Int? {
        guard !references.isEmpty else { return nil }
        prepareLayout()
        let glyph = layoutManager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard rect.contains(point) else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        return references.firstIndex { NSLocationInRange(character, $0.range) }
    }

    private func rect(of reference: PullRequestReference.Match) -> NSRect {
        prepareLayout()
        let glyphs = layoutManager.glyphRange(forCharacterRange: reference.range, actualCharacterRange: nil)
        return layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
    }

    private func setHovered(_ index: Int?) {
        guard hovered != index else { return }
        hovered = index
        storage.beginEditing()
        for (position, reference) in references.enumerated() {
            if position == index {
                storage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.single.rawValue,
                    range: reference.range
                )
            } else {
                storage.removeAttribute(.underlineStyle, range: reference.range)
            }
        }
        storage.endEditing()
        needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for reference in references {
            let rect = rect(of: reference)
            guard !rect.isEmpty, bounds.intersects(rect) else { continue }
            addCursorRect(rect.intersection(bounds), cursor: .pointingHand)
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hoverChanged?(true)
        setHovered(reference(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseMoved(with event: NSEvent) {
        setHovered(reference(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        hoverChanged?(false)
        setHovered(nil)
    }

    /// Taken so the view is the one that hears the mouse going up. What it does
    /// waits for that release, the way a button does.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        if let index = reference(at: point) {
            openReference?(references[index].number)
        } else {
            otherClick?()
        }
    }
}
