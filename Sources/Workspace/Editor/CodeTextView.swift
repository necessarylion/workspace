import AppKit

/// The editing surface: an `NSTextView` taught the few habits a code editor
/// needs — spaces for tab, indentation that follows the previous line, matching
/// brackets, a highlighted caret line, and hooks for ⌘-click and hover.
final class CodeTextView: NSTextView {
    var theme: SyntaxTheme = .standard {
        didSet { applyTheme() }
    }

    /// Spaces inserted for one Tab.
    var indentWidth = 4

    /// ⌘-click on a character offset — used for go-to-definition.
    var onCommandClick: ((Int) -> Void)?
    /// The mouse rested over a character offset (nil once it leaves).
    var onHover: ((Int?) -> Void)?
    /// ⌃Space.
    var onRequestCompletion: (() -> Void)?
    /// The caret moved.
    var onSelectionChange: (() -> Void)?

    private var trackingArea: NSTrackingArea?

    // MARK: - Set-up

    /// Builds a TextKit 1 text view. TextKit 1 is deliberate: the line-number
    /// ruler needs `NSLayoutManager` line fragments.
    static func make(theme: SyntaxTheme) -> CodeTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let container = NSTextContainer(size: CGSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)

        let textView = CodeTextView(frame: .zero, textContainer: container)
        textView.theme = theme
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        // No autoresizing while the text view sizes itself to the text: the
        // clip view would fight `sizeToFit` on every layout pass. The wrapping
        // setter puts `.width` back when the container tracks the view.
        textView.autoresizingMask = []
        textView.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = CGSize(width: 0, height: 0)
        textView.textContainerInset = CGSize(width: 6, height: 8)
        textView.applyTheme()
        return textView
    }

    func applyTheme() {
        font = theme.font
        textColor = theme.text
        backgroundColor = theme.background
        insertionPointColor = theme.text
        typingAttributes = [
            .font: theme.font,
            .foregroundColor: theme.text,
            .paragraphStyle: paragraphStyle
        ]
        defaultParagraphStyle = paragraphStyle
        needsDisplay = true
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = theme.lineHeightMultiple
        style.defaultTabInterval = theme.font.pointSize * 0.6 * CGFloat(indentWidth)
        style.tabStops = []
        return style
    }

    /// True when the text container is set to wrap.
    var wrapsLines: Bool {
        get { textContainer?.widthTracksTextView ?? false }
        set {
            guard let textContainer, let scrollView = enclosingScrollView else { return }
            textContainer.widthTracksTextView = newValue
            if newValue {
                textContainer.size = CGSize(
                    width: scrollView.contentSize.width,
                    height: CGFloat.greatestFiniteMagnitude
                )
                isHorizontallyResizable = false
                frame.size.width = scrollView.contentSize.width
                scrollView.hasHorizontalScroller = false
            } else {
                textContainer.size = CGSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude)
                isHorizontallyResizable = true
                scrollView.hasHorizontalScroller = true
            }
            needsLayout = true
        }
    }

    // MARK: - Caret line

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard selectedRange().length == 0,
              let layoutManager,
              let container = textContainer else { return }

        let caret = min(selectedRange().location, (string as NSString).length)
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: caret)
        var fragment = layoutManager.isValidGlyphIndex(glyphIndex)
            ? layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            : layoutManager.extraLineFragmentRect

        guard !fragment.isEmpty else { return }
        fragment.origin.x = 0
        fragment.size.width = max(bounds.width, container.size.width)
        fragment = fragment.offsetBy(dx: 0, dy: textContainerOrigin.y)

        theme.currentLine.setFill()
        fragment.fill()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Repaint so the caret-line band follows the caret.
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        onSelectionChange?()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        // ⌃Space asks the language server for completions.
        if event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == " " {
            onRequestCompletion?()
            return
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        insertText(String(repeating: " ", count: indentWidth), replacementRange: selectedRange())
    }

    override func insertBacktab(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = text.substring(with: lineRange)
        let leading = line.prefix { $0 == " " }
        guard !leading.isEmpty else { return }

        let removal = min(indentWidth, leading.count)
        let target = NSRange(location: lineRange.location, length: removal)
        guard shouldChangeText(in: target, replacementString: "") else { return }
        replaceCharacters(in: target, with: "")
        didChangeText()
    }

    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let caret = selectedRange()
        let lineRange = text.lineRange(for: NSRange(location: caret.location, length: 0))
        let lineUpToCaret = text.substring(
            with: NSRange(location: lineRange.location, length: caret.location - lineRange.location)
        )

        var indent = String(lineUpToCaret.prefix { $0 == " " || $0 == "\t" })
        let trimmed = lineUpToCaret.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("{") || trimmed.hasSuffix("(") || trimmed.hasSuffix("[") || trimmed.hasSuffix(":") {
            indent += String(repeating: " ", count: indentWidth)
        }

        // Typing Return between a pair of braces opens a block and leaves the
        // closing brace on its own line.
        let nextCharacter: String? = caret.location < text.length
            ? text.substring(with: NSRange(location: caret.location, length: 1))
            : nil
        let closingPair = ["{": "}", "(": ")", "[": "]"][String(trimmed.suffix(1))]

        if let nextCharacter, let closingPair, nextCharacter == closingPair {
            let outerIndent = String(lineUpToCaret.prefix { $0 == " " || $0 == "\t" })
            insertText("\n" + indent + "\n" + outerIndent, replacementRange: caret)
            setSelectedRange(NSRange(location: caret.location + 1 + indent.count, length: 0))
            return
        }

        insertText("\n" + indent, replacementRange: caret)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let inserted = string as? String else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }

        // Close brackets and quotes, and type over a closing character that is
        // already there.
        let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]
        let text = self.string as NSString
        let caret = replacementRange.length > 0 ? replacementRange : selectedRange()

        if replacementRange.length == 0 || caret.length == 0,
           let closing = pairs[inserted] {
            let next = caret.location < text.length
                ? text.substring(with: NSRange(location: caret.location, length: 1))
                : ""
            // Skip over a closing character we inserted a moment ago.
            if inserted == closing, next == closing {
                setSelectedRange(NSRange(location: caret.location + 1, length: 0))
                return
            }
            // Only auto-close before whitespace or a closer, never mid-word.
            if next.isEmpty || next.rangeOfCharacter(from: .alphanumerics) == nil {
                super.insertText(inserted + closing, replacementRange: caret)
                setSelectedRange(NSRange(location: caret.location + 1, length: 0))
                return
            }
        }

        if [")", "]", "}"].contains(inserted),
           caret.length == 0,
           caret.location < text.length,
           text.substring(with: NSRange(location: caret.location, length: 1)) == inserted {
            setSelectedRange(NSRange(location: caret.location + 1, length: 0))
            return
        }

        super.insertText(inserted, replacementRange: replacementRange)
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let offset = characterIndexForInsertion(at: point)
            onCommandClick?(offset)
            return
        }
        super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else {
            onHover?(nil)
            return
        }
        onHover?(characterIndexForInsertion(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        onHover?(nil)
        super.scrollWheel(with: event)
    }

    // MARK: - Geometry helpers

    /// Rect of a character offset in window coordinates, for popovers.
    func boundingRect(forOffset offset: Int) -> NSRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let clamped = min(max(offset, 0), (string as NSString).length)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: clamped, length: 0),
            actualCharacterRange: nil
        )
        var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        rect = rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return rect
    }
}
