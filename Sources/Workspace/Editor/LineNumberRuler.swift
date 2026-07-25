import AppKit

/// Gutter: line numbers plus a diagnostic marker per line.
///
/// Line starts are cached so scrolling never rescans the document; the cache is
/// rebuilt only when the controller reports an edit.
final class LineNumberRuler: NSRulerView {
    var theme: SyntaxTheme = .standard {
        didSet { needsDisplay = true }
    }

    /// Worst diagnostic severity per zero-based line.
    var diagnosticMarkers: [Int: LSP.Severity] = [:] {
        didSet { needsDisplay = true }
    }

    private var lineStarts: [Int] = [0]
    private var needsLineRebuild = true

    private var textView: NSTextView? {
        clientView as? NSTextView
    }

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = 46
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Call after every text change.
    func invalidateLines() {
        needsLineRebuild = true
        needsDisplay = true
    }

    var lineCount: Int {
        rebuildLineStartsIfNeeded()
        return lineStarts.count
    }

    /// Zero-based line containing a UTF-16 offset.
    func line(for offset: Int) -> Int {
        rebuildLineStartsIfNeeded()
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if lineStarts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low
    }

    /// Start offset of a zero-based line, clamped to the document.
    func offset(forLine line: Int) -> Int {
        rebuildLineStartsIfNeeded()
        guard !lineStarts.isEmpty else { return 0 }
        return lineStarts[min(max(line, 0), lineStarts.count - 1)]
    }

    private func rebuildLineStartsIfNeeded() {
        guard needsLineRebuild, let string = textView?.string else { return }
        needsLineRebuild = false
        var starts: [Int] = [0]
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        // A trailing newline opens a final, empty line — keep it numbered.
        lineStarts = starts
    }

    /// Sizes the gutter to the widest line number.
    func updateThickness() {
        let digits = max(2, String(lineCount).count)
        let width = ceil(CGFloat(digits) * theme.font.pointSize * 0.62) + 30
        if abs(width - ruleThickness) > 0.5 {
            ruleThickness = width
        }
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        rebuildLineStartsIfNeeded()

        // AppKit does not clip ruler drawing, and the dirty rect can be both
        // wider and taller than the gutter (its y can even be negative) — an
        // unclipped fill paints over the text and whatever sits above the
        // scroll view. Clip everything to the gutter itself.
        NSGraphicsContext.current?.saveGraphicsState()
        defer { NSGraphicsContext.current?.restoreGraphicsState() }
        bounds.clip()

        theme.gutterBackground.setFill()
        bounds.fill()

        let visibleRect = scrollView?.contentView.bounds ?? textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        let firstLine = line(for: characterRange.location)
        let lastLine = line(for: NSMaxRange(characterRange))
        let inset = textView.textContainerOrigin
        let caretLine = line(for: textView.selectedRange().location)
        let documentLength = (textView.string as NSString).length

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: theme.font.pointSize - 1, weight: .regular),
            .foregroundColor: theme.gutterText
        ]
        let caretAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: theme.font.pointSize - 1, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        for lineIndex in firstLine...max(firstLine, lastLine) {
            guard lineIndex < lineStarts.count else { break }
            let start = lineStarts[lineIndex]

            let fragment: NSRect
            if start >= documentLength {
                // The empty line after a trailing newline, or an empty file.
                fragment = layoutManager.extraLineFragmentRect
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: start)
                guard layoutManager.isValidGlyphIndex(glyphIndex) else { continue }
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            }
            guard !fragment.isEmpty else { continue }

            let y = fragment.minY + inset.y - visibleRect.minY
            drawMarker(forLine: lineIndex, y: y, height: fragment.height)

            let label = "\(lineIndex + 1)" as NSString
            let chosen = lineIndex == caretLine ? caretAttributes : attributes
            let size = label.size(withAttributes: chosen)
            label.draw(
                at: NSPoint(
                    x: bounds.width - size.width - 12,
                    y: y + (fragment.height - size.height) / 2
                ),
                withAttributes: chosen
            )
        }
    }

    private func drawMarker(forLine line: Int, y: CGFloat, height: CGFloat) {
        guard let severity = diagnosticMarkers[line] else { return }
        let color: NSColor = switch severity {
        case .error: .systemRed
        case .warning: .systemOrange
        case .information: .systemBlue
        case .hint: .systemGray
        }
        let diameter: CGFloat = 7
        let dot = NSRect(x: 6, y: y + (height - diameter) / 2, width: diameter, height: diameter)
        color.setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}
