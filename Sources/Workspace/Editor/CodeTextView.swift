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
    /// The mouse moved over a character offset with ⌘ held (nil when it left,
    /// or when ⌘ came back up) — used to underline what ⌘-click would open.
    var onCommandHover: ((Int?) -> Void)?
    /// The mouse rested over a character offset (nil once it leaves).
    var onHover: ((Int?) -> Void)?

    /// The range currently drawn as a link, set by the controller once the
    /// language server confirms there is somewhere to go.
    var linkRange: NSRange? {
        didSet {
            guard linkRange != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }
    /// ⌃Space.
    var onRequestCompletion: (() -> Void)?
    /// The caret moved.
    var onSelectionChange: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var flagsMonitor: Any?

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
            } else {
                textContainer.size = CGSize(width: 10_000_000, height: CGFloat.greatestFiniteMagnitude)
                isHorizontallyResizable = true
            }
            // The horizontal scroller stays enabled either way: it is a
            // `HiddenScroller`, so it costs no space, and toggling it off would
            // have AppKit replace it with a stock one when wrapping is turned off.
            needsLayout = true
        }
    }

    // MARK: - Caret line and indent guides

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCaretLine()
        drawIndentGuides(in: rect)
    }

    private func drawCaretLine() {
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

    /// One hairline per level of indentation, the way an editor shows which
    /// block a line belongs to. Only the lines inside `rect` are walked.
    private func drawIndentGuides(in rect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }
        let text = string as NSString
        guard text.length > 0, indentWidth > 0 else { return }

        // Measured rather than taken from the font's maximum advance, which is
        // wrong for any font that is not strictly monospaced.
        let columnWidth = (" " as NSString).size(withAttributes: [.font: theme.font]).width
        guard columnWidth > 0 else { return }
        let step = columnWidth * CGFloat(indentWidth)
        let origin = textContainerOrigin

        // Which lines are actually on screen.
        let visible = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphRange.length > 0 else { return }
        let charRange = text.lineRange(
            for: layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        )

        theme.indentGuide.setFill()
        let thickness: CGFloat = 1
        let end = NSMaxRange(charRange)
        var location = charRange.location

        while location < end {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            location = max(NSMaxRange(lineRange), location + 1)

            let levels = guideColumns(ofLineAt: lineRange, in: text) / indentWidth
            guard levels > 0 else { continue }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            guard layoutManager.isValidGlyphIndex(glyphIndex) else { continue }
            var fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            guard !fragment.isEmpty else { continue }
            fragment = fragment.offsetBy(dx: origin.x, dy: origin.y)

            for level in 0..<levels {
                // Set into the character cell rather than on the column
                // boundary, so the rule sits between the text and its edge.
                let x = (fragment.minX + CGFloat(level) * step + columnWidth * 0.8).rounded()
                NSRect(x: x, y: fragment.minY, width: thickness, height: fragment.height).fill()
            }
        }
    }

    /// The indentation of a line in columns. Blank lines borrow the smaller
    /// indentation of their nearest non-blank neighbours, so a guide runs
    /// through the empty lines inside a block instead of breaking up.
    private func guideColumns(ofLineAt lineRange: NSRange, in text: NSString) -> Int {
        if let own = indentColumns(ofLineAt: lineRange, in: text) { return own }

        var above = 0
        var location = lineRange.location
        var steps = 0
        while location > 0, steps < 200 {
            let previous = text.lineRange(for: NSRange(location: location - 1, length: 0))
            if let columns = indentColumns(ofLineAt: previous, in: text) {
                above = columns
                break
            }
            location = previous.location
            steps += 1
        }

        var below = 0
        location = NSMaxRange(lineRange)
        steps = 0
        while location < text.length, steps < 200 {
            let next = text.lineRange(for: NSRange(location: location, length: 0))
            if let columns = indentColumns(ofLineAt: next, in: text) {
                below = columns
                break
            }
            location = max(NSMaxRange(next), location + 1)
            steps += 1
        }

        return min(above, below)
    }

    /// Nil for a line that holds nothing but whitespace.
    private func indentColumns(ofLineAt lineRange: NSRange, in text: NSString) -> Int? {
        var columns = 0
        var index = lineRange.location
        let end = NSMaxRange(lineRange)
        while index < end {
            switch text.character(at: index) {
            case 0x20: columns += 1
            case 0x09: columns += indentWidth - (columns % indentWidth)
            case 0x0A, 0x0D: return nil
            default: return columns
            }
            index += 1
        }
        return nil
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

    /// Whether the completion list `complete(_:)` puts up is on screen.
    ///
    /// ⎋ closes the file otherwise (see `EscapeKey`), and while this list is up
    /// ⎋ is the list's — dismissing it is the only way out of a completion you
    /// did not want. `NSTextView` publishes no flag for it, so the two ends of
    /// its own lifecycle are watched instead.
    private(set) var isShowingCompletions = false

    override func complete(_ sender: Any?) {
        super.complete(sender)
        isShowingCompletions = true
    }

    /// AppKit calls this however the list ends — a word picked, ⎋, or a click
    /// somewhere else — with `flag` set on the last of them.
    override func insertCompletion(
        _ word: String,
        forPartialWordRange charRange: NSRange,
        movement: Int,
        isFinal flag: Bool
    ) {
        super.insertCompletion(
            word,
            forPartialWordRange: charRange,
            movement: movement,
            isFinal: flag
        )
        if flag { isShowingCompletions = false }
    }

    /// Belt and braces: focus cannot leave with the list still up, and a flag
    /// left stuck on would cost the user ⎋ for the rest of the session.
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { isShowingCompletions = false }
        return resigned
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
            options: [
                .mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                .activeInKeyWindow, .inVisibleRect
            ],
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
            onCommandHover?(nil)
            return
        }
        let offset = characterIndexForInsertion(at: point)
        if event.modifierFlags.contains(.command) {
            onCommandHover?(offset)
        } else {
            onCommandHover?(nil)
            onHover?(offset)
        }
        if let linkRange, NSLocationInRange(offset, linkRange) {
            NSCursor.pointingHand.set()
        }
    }

    /// Holding or releasing ⌘ without moving the mouse still has to arm or
    /// clear the link under the pointer.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        commandStateChanged(event)
    }

    /// ⌘ is reported to whoever is first responder, which is often not this
    /// view — a local monitor catches it wherever focus happens to be.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        guard window != nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.commandStateChanged(event)
            return event
        }
    }

    private func commandStateChanged(_ event: NSEvent) {
        guard let window, window.isKeyWindow else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard event.modifierFlags.contains(.command), visibleRect.contains(point) else {
            onCommandHover?(nil)
            return
        }
        onHover?(nil)
        onCommandHover?(characterIndexForInsertion(at: point))
    }

    override func cursorUpdate(with event: NSEvent) {
        if linkRange != nil {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    /// The link keeps the pointer a hand for as long as it is shown, whatever
    /// the text view would otherwise put there.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let range = linkRange, let rect = boundingRect(forRange: range) else { return }
        addCursorRect(rect, cursor: .pointingHand)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
        onCommandHover?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        onHover?(nil)
        onCommandHover?(nil)
        super.scrollWheel(with: event)
    }

    // MARK: - Geometry helpers

    /// Rect covering a character range, in this view's coordinates.
    func boundingRect(forRange range: NSRange) -> NSRect? {
        guard let layoutManager, let container = textContainer else { return nil }
        let length = (string as NSString).length
        guard NSMaxRange(range) <= length else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        guard !rect.isEmpty else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

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
