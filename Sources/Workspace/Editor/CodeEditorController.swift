import AppKit
import CodeEditLanguages

/// Owns the editing stack for one open file: scroll view, text view, gutter,
/// tree-sitter highlighting and the language server conversation.
@MainActor
final class CodeEditorController: NSViewController {
    // Set by the SwiftUI wrapper.
    var onTextChange: ((String) -> Void)?
    var onCaretChange: ((Int, Int) -> Void)?
    var onDiagnostics: (([LSP.Diagnostic]) -> Void)?
    var onSymbols: (([LSP.Symbol]) -> Void)?
    var onStatusChange: ((String) -> Void)?
    /// Go-to-definition landed somewhere: (file, zero-based line).
    var onOpenLocation: ((URL, Int) -> Void)?

    private(set) var fileURL: URL?
    private var projectRoot: URL?
    private var language: CodeLanguage = .default

    private var scrollView = NSScrollView()
    private(set) var textView: CodeTextView!
    private var ruler: LineNumberRuler!
    private var highlighter: TreeSitterHighlighter?
    private let hoverWindow = HoverInfoWindow()

    private var service: LanguageService?
    private var diagnostics: [LSP.Diagnostic] = []

    private var theme = SyntaxTheme.standard
    private var isApplyingExternalText = false
    private var isApplyingHighlight = false

    /// What the file search was looking for, so every place it occurs in this
    /// file is marked — the one hit that was clicked is rarely the only one
    /// worth seeing. Nil while no search is running.
    var searchHighlight: String? {
        didSet {
            guard searchHighlight != oldValue else { return }
            findSearchMatches()
            applySearchHighlight(in: nil)
        }
    }

    /// Where `searchHighlight` occurs, in order, found once per file rather than
    /// per re-colouring pass.
    private var searchMatches: [NSRange] = []
    private var searchRescan: Task<Void, Never>?
    /// The region already coloured, so plain scrolling does no work until the
    /// viewport leaves it.
    private var highlightedRange = NSRange(location: 0, length: 0)

    private var syncTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var linkTask: Task<Void, Never>?
    private var symbolTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var cachedCompletions: [String] = []

    var wrapsLines: Bool {
        get { textView?.wrapsLines ?? false }
        set { textView?.wrapsLines = newValue }
    }

    // MARK: - View

    override func loadView() {
        let textView = CodeTextView.make(theme: theme)
        self.textView = textView

        // A starting size matters: the scroll view is handed to SwiftUI, and a
        // zero-sized clip view shows nothing however well the text is laid out.
        let initialFrame = NSRect(x: 0, y: 0, width: 900, height: 600)
        scrollView.frame = initialFrame
        scrollView.autoresizingMask = [.width, .height]
        textView.frame = initialFrame

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        // Both axes stay enabled so the scroll view keeps handling them; the
        // scrollers themselves are invisible, like everywhere else in the app.
        scrollView.verticalScroller = HiddenScroller()
        scrollView.horizontalScroller = HiddenScroller()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background
        // The window uses a full-size content view, so AppKit would otherwise
        // inset this scroll view for a titlebar it does not actually sit under,
        // and tile the gutter above its own frame — the gutter then painted a
        // stray strip up through the header and toolbar.
        // NSView does not clip by default, so pin the insets and clip as well.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = .init()
        scrollView.scrollerInsets = .init()
        scrollView.clipsToBounds = true

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.theme = theme
        self.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.onCommandClick = { [weak self] offset in self?.jumpToDefinition(at: offset) }
        textView.onCommandHover = { [weak self] offset in self?.commandHoverChanged(to: offset) }
        textView.onHover = { [weak self] offset in self?.hoverChanged(to: offset) }
        textView.onRequestCompletion = { [weak self] in self?.requestCompletion() }
        textView.onSelectionChange = { [weak self] in self?.reportCaret() }

        // Repaint the gutter while scrolling.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appearanceMayHaveChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )

        view = scrollView
    }

    /// Whether to take the keyboard as the editor appears. Off when the file was
    /// opened from the file tree, which keeps the keys for its own ⏎ and ⌘⌫ —
    /// clicking the text still focuses it, as any text view does.
    var takesFocusOnAppear = true

    override func viewDidAppear() {
        super.viewDidAppear()
        guard takesFocusOnAppear else { return }
        view.window?.makeFirstResponder(textView)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Loading a file

    func load(url: URL, text: String, projectRoot: URL?) {
        guard fileURL != url else { return }
        detachService()

        fileURL = url
        self.projectRoot = projectRoot
        language = CodeLanguage.forFile(url: url)

        isApplyingExternalText = true
        textView.string = text
        isApplyingExternalText = false

        // Follow the file's own indentation, so Tab, backtab and the indent
        // guides all line up with what is already there.
        textView.indentWidth = Self.detectIndentWidth(in: text)

        if let highlighter {
            highlighter.setLanguage(language)
            highlighter.setText(text)
        } else {
            highlighter = TreeSitterHighlighter(language: language)
            highlighter?.setText(text)
        }

        applyBaseAttributes()
        findSearchMatches()
        ruler.invalidateLines()
        ruler.updateThickness()
        highlightVisible()
        reportCaret()

        attachService(text: text)
    }

    /// The file's own indent step, from the gaps between the indentation of
    /// consecutive lines. Falls back to four spaces when nothing is indented.
    private static func detectIndentWidth(in text: String) -> Int {
        var counts: [Int: Int] = [:]
        var previous = 0
        var scanned = 0

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard scanned < 500 else { break }
            // Tabs are their own unit; a tab-indented file needs no guessing.
            if line.hasPrefix("\t") { return 4 }
            let indent = line.prefix { $0 == " " }.count
            guard line.count > indent else { continue }
            scanned += 1
            let step = indent - previous
            if step > 0, step <= 8 { counts[step, default: 0] += 1 }
            previous = indent
        }

        // Ties go to the larger step: two levels of two look like one of four
        // only when four is genuinely as common.
        let best = counts.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value < rhs.value
        }
        return best?.key ?? 4
    }

    /// Replaces the buffer when the file changed on disk.
    func replaceText(_ text: String) {
        guard textView.string != text else { return }
        let caret = textView.selectedRange()
        isApplyingExternalText = true
        textView.string = text
        isApplyingExternalText = false

        highlighter?.setText(text)
        applyBaseAttributes()
        findSearchMatches()
        ruler.invalidateLines()
        ruler.updateThickness()
        highlightVisible()

        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(caret.location, length), length: 0))
        Task { await service?.change(uri: uri, text: text) }
    }

    func updateTheme(_ theme: SyntaxTheme) {
        self.theme = theme
        textView.theme = theme
        ruler.theme = theme
        scrollView.backgroundColor = theme.background
        applyBaseAttributes()
        // The gutter is sized from the font, so a size change moves the text.
        ruler.updateThickness()
        highlightVisible()
    }

    /// The face, size, line spacing and colours chosen in Settings. Applied
    /// before the view is loaded it only seeds the theme, so the first layout
    /// already uses them rather than laying the file out twice.
    func applyAppearance(_ theme: SyntaxTheme) {
        guard self.theme != theme else { return }
        if isViewLoaded {
            updateTheme(theme)
        } else {
            self.theme = theme
        }
    }

    /// Scrolls a zero-based line into view and puts the caret on it.
    func reveal(line: Int) {
        let offset = ruler.offset(forLine: line)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
        // Centre it rather than leaving it glued to the bottom edge.
        if let rect = textView.boundingRect(forOffset: offset) {
            let target = NSRect(
                x: 0,
                y: max(rect.midY - scrollView.contentSize.height / 2, 0),
                width: 1,
                height: scrollView.contentSize.height
            )
            textView.scrollToVisible(target)
        }
        view.window?.makeFirstResponder(textView)
    }

    func focus() {
        view.window?.makeFirstResponder(textView)
    }

    // MARK: - Find in file

    /// How many places the current query occurs. The find bar counts with this
    /// rather than searching the text a second time of its own.
    var searchMatchCount: Int { searchMatches.count }

    /// Selects the match after the caret — or the one before it — scrolls it
    /// into view and flashes it. Returns which match that was, counted from 1,
    /// or 0 when the file has none.
    ///
    /// It wraps at both ends: a file is searched by pressing ⏎ until the thing
    /// you wanted goes past, and stopping dead at the last hit only makes that
    /// take two hands.
    @discardableResult
    func goToSearchMatch(forward: Bool) -> Int {
        guard isViewLoaded, !searchMatches.isEmpty else { return 0 }
        let caret = textView.selectedRange()

        let index: Int
        if forward {
            // Anything starting at or after the end of the selection. With the
            // caret sitting on a match that is the *next* one, and with a plain
            // caret it is the first hit from here down.
            index = searchMatches.firstIndex { $0.location >= NSMaxRange(caret) } ?? 0
        } else {
            index = searchMatches.lastIndex { NSMaxRange($0) <= caret.location }
                ?? searchMatches.count - 1
        }

        let match = searchMatches[index]
        textView.setSelectedRange(match)
        textView.scrollRangeToVisible(match)
        // Centred, for the same reason `reveal(line:)` centres: a hit found at
        // the very bottom of the pane is a hit with no context under it.
        if let rect = textView.boundingRect(forOffset: match.location) {
            let target = NSRect(
                x: 0,
                y: max(rect.midY - scrollView.contentSize.height / 2, 0),
                width: 1,
                height: scrollView.contentSize.height
            )
            textView.scrollToVisible(target)
        }
        // The system's own "here it is" bubble, which survives the yellow the
        // other matches are already wearing.
        textView.showFindIndicator(for: match)
        return index + 1
    }

    // MARK: - Language server

    private var uri: String { fileURL?.absoluteString ?? "" }

    private func attachService(text: String) {
        guard let fileURL, let projectRoot,
              let service = LanguageServerRegistry.shared.service(for: fileURL, language: language, root: projectRoot) else {
            onStatusChange?("no language server")
            return
        }
        self.service = service
        service.addDiagnosticObserver(self) { [weak self] uri, diagnostics in
            guard let self, uri == fileURL.absoluteString else { return }
            self.apply(diagnostics: diagnostics)
        }

        onStatusChange?("\(service.definition.displayName) starting…")
        Task { [weak self] in
            await service.open(uri: fileURL.absoluteString, text: text)
            guard let self else { return }
            self.onStatusChange?("\(service.definition.displayName) \(service.status.label)")
            self.refreshSymbols()
        }
    }

    private func detachService() {
        guard let service, let fileURL else { return }
        service.removeDiagnosticObserver(self)
        let uri = fileURL.absoluteString
        Task { await service.close(uri: uri) }
        self.service = nil
        diagnostics = []
        onDiagnostics?([])
        onSymbols?([])
    }

    /// Called by the wrapper when the document is saved.
    func documentSaved() {
        guard let service, let fileURL else { return }
        let text = textView.string
        Task {
            await service.save(uri: fileURL.absoluteString, text: text)
        }
        refreshSymbols()
    }

    private func refreshSymbols() {
        guard let service, let fileURL else { return }
        symbolTask?.cancel()
        symbolTask = Task { [weak self] in
            let symbols = await service.symbols(uri: fileURL.absoluteString)
            guard !Task.isCancelled else { return }
            self?.onSymbols?(symbols)
        }
    }

    private func apply(diagnostics: [LSP.Diagnostic]) {
        self.diagnostics = diagnostics
        onDiagnostics?(diagnostics)

        var markers: [Int: LSP.Severity] = [:]
        for diagnostic in diagnostics {
            let level = diagnostic.level
            if let existing = markers[diagnostic.line], existing <= level { continue }
            markers[diagnostic.line] = level
        }
        ruler.diagnosticMarkers = markers
        applyDiagnosticUnderlines(in: nil)
    }

    /// Underlines diagnostics. With a range, only re-adds the ones inside it
    /// (the caller just wiped that range's attributes); with nil, clears the
    /// whole document first — that pass is expensive, so it only runs when the
    /// diagnostics themselves change.
    private func applyDiagnosticUnderlines(in target: NSRange?) {
        guard let storage = textView.textStorage else { return }
        isApplyingHighlight = true
        storage.beginEditing()

        if target == nil {
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.underlineStyle, range: full)
            storage.removeAttribute(.underlineColor, range: full)
        }

        for diagnostic in diagnostics {
            guard var range = range(for: diagnostic.range), range.length > 0 else { continue }
            if let target {
                range = NSIntersectionRange(range, target)
                guard range.length > 0 else { continue }
            }
            let color: NSColor = switch diagnostic.level {
            case .error: .systemRed
            case .warning: .systemOrange
            default: .systemBlue
            }
            storage.addAttributes(
                [
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: color
                ],
                range: range
            )
        }
        storage.endEditing()
        isApplyingHighlight = false
    }

    // MARK: - Search matches

    /// Every occurrence of the query, literal and case-insensitive — the same
    /// terms the search pane found them with.
    ///
    /// `.literal` is both the faster comparison and the truer one here: without
    /// it a search walks the text looking for canonically equivalent forms,
    /// which is not what the tools that found these files matched on.
    private func findSearchMatches() {
        searchMatches = []
        searchRescan?.cancel()
        guard let query = searchHighlight, !query.isEmpty,
              let text = textView?.textStorage?.string as NSString?
        else { return }

        var start = 0
        while start < text.length {
            let remaining = NSRange(location: start, length: text.length - start)
            let found = text.range(of: query, options: [.caseInsensitive, .literal], range: remaining)
            guard found.location != NSNotFound, found.length > 0 else { break }
            searchMatches.append(found)
            start = NSMaxRange(found)
        }
    }

    /// Moves the known matches out of an edit's way, so the marks stay under the
    /// right words between the keystroke and the rescan. Everything before the
    /// edit is where it was, everything after it slides by the change in length,
    /// and anything the edit ran through is dropped until the rescan looks
    /// again. That is a walk over the matches rather than over the file.
    private func shiftSearchMatches(edited: NSRange, delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let replaced = NSRange(location: edited.location, length: max(edited.length - delta, 0))
        let end = NSMaxRange(replaced)
        searchMatches = searchMatches.compactMap { match in
            if NSMaxRange(match) <= replaced.location { return match }
            guard match.location >= end else { return nil }
            return NSRange(location: match.location + delta, length: match.length)
        }
    }

    /// Re-finds the matches once typing stops. Scanning the whole file per
    /// keystroke is the one cost worth avoiding here; the shifted ranges hold
    /// the picture together until this lands.
    private func scheduleSearchRescan() {
        searchRescan?.cancel()
        searchRescan = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, searchHighlight != nil else { return }
            findSearchMatches()
            applySearchHighlight(in: nil)
        }
    }

    /// The matches overlapping `target`, by binary search. They are found in
    /// order, so a re-colouring pass touches the handful on screen instead of
    /// walking every hit in the file — which is what makes scrolling a file with
    /// a thousand of them cost the same as a file with three.
    private func searchMatches(overlapping target: NSRange) -> ArraySlice<NSRange> {
        var low = 0
        var high = searchMatches.count
        while low < high {
            let middle = (low + high) / 2
            if NSMaxRange(searchMatches[middle]) <= target.location {
                low = middle + 1
            } else {
                high = middle
            }
        }
        let limit = NSMaxRange(target)
        var end = low
        while end < searchMatches.count, searchMatches[end].location < limit { end += 1 }
        return searchMatches[low..<end]
    }

    /// Marks the matches, the way the find bar's "highlight all" does. Follows
    /// ``applyDiagnosticUnderlines(in:)``: with a range it only re-adds the ones
    /// inside it, because the caller has just wiped that range's attributes.
    private func applySearchHighlight(in target: NSRange?) {
        guard let storage = textView?.textStorage else { return }
        // The common case by far: no search running, and a scroll pass that
        // should cost nothing at all.
        guard target == nil || !searchMatches.isEmpty else { return }

        let full = NSRange(location: 0, length: storage.length)
        let painted = target.map { NSIntersectionRange($0, full) }
        let due = painted.map(searchMatches(overlapping:)) ?? searchMatches[...]
        guard painted == nil || !due.isEmpty else { return }

        isApplyingHighlight = true
        storage.beginEditing()
        if painted == nil {
            storage.removeAttribute(.backgroundColor, range: full)
        }
        let colour = NSColor.systemYellow.withAlphaComponent(0.32)
        for match in due {
            let range = NSIntersectionRange(match, painted ?? full)
            guard range.length > 0 else { continue }
            storage.addAttribute(.backgroundColor, value: colour, range: range)
        }
        storage.endEditing()
        isApplyingHighlight = false
    }

    // MARK: - Position conversion

    /// LSP position (line, UTF-16 character) to a text offset.
    private func offset(for position: LSP.Position) -> Int {
        let lineStart = ruler.offset(forLine: position.line)
        let text = textView.string as NSString
        let lineRange = text.lineRange(for: NSRange(location: min(lineStart, text.length), length: 0))
        return min(lineStart + position.character, NSMaxRange(lineRange))
    }

    private func range(for range: LSP.Range) -> NSRange? {
        let start = offset(for: range.start)
        let end = offset(for: range.end)
        guard end >= start else { return nil }
        let length = (textView.string as NSString).length
        guard start <= length else { return nil }
        return NSRange(location: start, length: min(end, length) - start)
    }

    private func position(for offset: Int) -> LSP.Position {
        let line = ruler.line(for: offset)
        return LSP.Position(line: line, character: offset - ruler.offset(forLine: line))
    }

    // MARK: - Highlighting

    private func applyBaseAttributes() {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        isApplyingHighlight = true
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: theme.font,
                .foregroundColor: theme.text,
                .paragraphStyle: textView.paragraphStyle
            ],
            range: full
        )
        storage.endEditing()
        isApplyingHighlight = false
        highlightedRange = NSRange(location: 0, length: 0)
    }

    /// Re-colours the visible region plus a screen of padding.
    private func highlightVisible() {
        guard let highlighter, highlighter.isReady, let storage = textView.textStorage else { return }

        let length = storage.length
        guard length > 0 else { return }

        let visible = visibleCharacterRange()
        // Two screens of padding each way, so fast scrolling rarely has to
        // stop and re-colour.
        let padding = max(visible.length * 2, 4_000)
        let start = max(0, visible.location - padding)
        let end = min(length, NSMaxRange(visible) + padding)
        guard end > start else { return }
        let target = NSRange(location: start, length: end - start)

        isApplyingHighlight = true
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: theme.font,
                .foregroundColor: theme.text,
                .paragraphStyle: textView.paragraphStyle
            ],
            range: target
        )
        for highlight in highlighter.highlights(in: target) {
            let clamped = NSIntersectionRange(highlight.range, target)
            guard clamped.length > 0 else { continue }
            storage.addAttributes(theme.attributes(for: highlight.capture), range: clamped)
        }
        storage.endEditing()
        isApplyingHighlight = false
        highlightedRange = target

        // setAttributes just wiped the underlines and the search marks in
        // `target`; put back only the ones that fall inside it.
        applyDiagnosticUnderlines(in: target)
        applySearchHighlight(in: target)
    }

    private func visibleCharacterRange() -> NSRange {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else {
            return NSRange(location: 0, length: 0)
        }
        let rect = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: rect, in: container)
        return layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    @objc private func viewportChanged() {
        hoverWindow.hide()
        ruler.needsDisplay = true

        // Scrolling inside the already-coloured region costs nothing; only
        // re-colour when the viewport leaves it.
        let visible = visibleCharacterRange()
        let contained = visible.length == 0
            || NSIntersectionRange(visible, highlightedRange).length == visible.length
        if !contained {
            highlightVisible()
        }
    }

    @objc private func appearanceMayHaveChanged() {
        applyBaseAttributes()
        highlightVisible()
    }

    private func reportCaret() {
        let offset = textView.selectedRange().location
        let line = ruler.line(for: offset)
        onCaretChange?(line + 1, offset - ruler.offset(forLine: line) + 1)
    }

    // MARK: - Hover

    private func hoverChanged(to offset: Int?) {
        hoverTask?.cancel()
        guard let offset else {
            hoverWindow.hide()
            return
        }

        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }

            // A diagnostic under the cursor wins: it is the more urgent message.
            if let diagnostic = diagnostics.first(where: { candidate in
                guard let range = self.range(for: candidate.range) else { return false }
                return NSLocationInRange(offset, range) || range.location == offset
            }) {
                showHover(
                    text: diagnostic.source.map { "\($0): \(diagnostic.message)" } ?? diagnostic.message,
                    symbol: diagnostic.level.symbol,
                    tint: diagnostic.level == .error ? .systemRed : .systemOrange,
                    at: offset
                )
                return
            }

            guard let service, let fileURL, service.status.isHealthy else { return }
            let text = await service.hover(uri: fileURL.absoluteString, position: position(for: offset))
            guard !Task.isCancelled, let text, !text.isEmpty else { return }
            showHover(text: text, symbol: nil, tint: .labelColor, at: offset)
        }
    }

    private func showHover(text: String, symbol: String?, tint: NSColor, at offset: Int) {
        guard let rect = textView.boundingRect(forOffset: offset) else { return }
        hoverWindow.show(text: text, symbol: symbol, tint: tint, below: rect, in: textView)
    }

    // MARK: - Go to definition

    private func jumpToDefinition(at offset: Int) {
        clearLink()
        guard let fileURL else { return }
        guard let service else {
            onStatusChange?("No language server for \(language.id.rawValue)")
            return
        }
        guard service.status.isHealthy else {
            onStatusChange?("\(service.definition.displayName): \(service.status.label)")
            return
        }

        let target = position(for: offset)
        onStatusChange?("Looking for the definition…")
        Task { [weak self] in
            let locations = await service.definitions(
                uri: fileURL.absoluteString,
                position: target
            )
            guard let self else { return }
            guard let locations else {
                onStatusChange?("\(service.definition.displayName) did not answer — it may still be indexing")
                return
            }
            guard let target = locations.first, let url = target.fileURL else {
                // Silence here is what made this look broken; say so instead.
                onStatusChange?("No definition found")
                return
            }
            onStatusChange?("\(service.definition.displayName) \(service.status.label)")
            if url == fileURL {
                reveal(line: target.range.start.line)
            } else {
                onOpenLocation?(url, target.range.start.line)
            }
        }
    }

    /// ⌘ held over a symbol: ask the server whether there is anywhere to go and,
    /// if so, underline it and switch the pointer to a hand.
    private func commandHoverChanged(to offset: Int?) {
        linkTask?.cancel()
        guard let offset,
              let service,
              let fileURL,
              service.status.isHealthy,
              let word = wordRange(at: offset) else {
            clearLink()
            return
        }
        if textView.linkRange == word { return }

        // Underline straight away: waiting for the server first made ⌘-hover
        // feel dead. If it turns out there is nowhere to go, take it back.
        showLink(over: word)

        let target = position(for: offset)
        linkTask = Task { [weak self] in
            let locations = await service.definitions(uri: fileURL.absoluteString, position: target)
            guard !Task.isCancelled, let self, textView.linkRange == word else { return }
            if locations?.isEmpty ?? true { clearLink() }
        }
    }

    private func showLink(over range: NSRange) {
        guard let layoutManager = textView.layoutManager else { return }
        clearLink()
        // Temporary attributes: the document itself is untouched, so this never
        // shows up as an edit or fights the syntax colouring.
        layoutManager.addTemporaryAttributes(
            [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: theme.text
            ],
            forCharacterRange: range
        )
        textView.linkRange = range
        textView.window?.invalidateCursorRects(for: textView)
        NSCursor.pointingHand.set()
    }

    private func clearLink() {
        guard let range = textView.linkRange else { return }
        if let layoutManager = textView.layoutManager,
           NSMaxRange(range) <= (textView.string as NSString).length {
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: range)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: range)
        }
        textView.linkRange = nil
        NSCursor.iBeam.set()
    }

    /// The identifier around an offset — what the underline should cover.
    private func wordRange(at offset: Int) -> NSRange? {
        let text = textView.string as NSString
        guard offset >= 0, offset <= text.length else { return nil }

        func isWord(_ character: unichar) -> Bool {
            let scalar = UnicodeScalar(character)
            guard let scalar else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }

        var start = offset
        while start > 0, isWord(text.character(at: start - 1)) { start -= 1 }
        var end = offset
        while end < text.length, isWord(text.character(at: end)) { end += 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    // MARK: - Completion

    private func requestCompletion() {
        guard let service, let fileURL, service.status.isHealthy else { return }
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard let self else { return }
            let caret = textView.selectedRange().location
            let items = await service.completions(
                uri: fileURL.absoluteString,
                position: position(for: caret)
            )
            guard !Task.isCancelled, !items.isEmpty else { return }

            // NSTextView's completion list takes plain strings; keep the order
            // the server asked for.
            let sorted = items.sorted { lhs, rhs in
                (lhs.sortText ?? lhs.label) < (rhs.sortText ?? rhs.label)
            }
            cachedCompletions = Array(sorted.map(\.text).uniqued().prefix(60))
            textView.complete(nil)
        }
    }
}

// MARK: - Text storage

extension CodeEditorController: NSTextStorageDelegate {
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let snapshot = textStorage.string
        MainActor.assumeIsolated {
            guard !isApplyingHighlight else { return }
            handleEdit(range: editedRange, delta: delta, text: snapshot)
        }
    }

    private func handleEdit(range: NSRange, delta: Int, text: String) {
        highlighter?.apply(editedRange: range, changeInLength: delta, newText: text)
        ruler.invalidateLines()
        // An edit moves every match after it, and can make or unmake one. The
        // cheap half is done now so nothing is drawn in the wrong place; the
        // scan waits for a pause in the typing.
        if searchHighlight != nil {
            shiftSearchMatches(edited: range, delta: delta)
            scheduleSearchRescan()
        }

        // Anything that lays out text — re-colouring, and resizing the gutter,
        // which re-tiles the scroll view — has to wait until the storage has
        // finished its edit pass. Doing it here crashes the layout manager.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ruler.updateThickness()
            highlightVisible()
            reportCaret()
        }

        guard !isApplyingExternalText else { return }
        onTextChange?(text)

        // Debounce the server: one didChange per pause in typing.
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let service, let fileURL else { return }
            await service.change(uri: fileURL.absoluteString, text: text)
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            refreshSymbols()
        }
    }
}

// MARK: - Text view delegate

extension CodeEditorController: NSTextViewDelegate {
    func textView(
        _ textView: NSTextView,
        completions words: [String],
        forPartialWordRange charRange: NSRange,
        indexOfSelectedItem index: UnsafeMutablePointer<Int>?
    ) -> [String] {
        guard !cachedCompletions.isEmpty else { return words }
        let partial = (textView.string as NSString).substring(with: charRange)
        guard !partial.isEmpty else { return cachedCompletions }
        let matches = cachedCompletions.filter { $0.hasPrefix(partial) }
        return matches.isEmpty ? cachedCompletions : matches
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        hoverWindow.hide()
    }
}

private extension Array where Element: Hashable {
    /// Keeps the first occurrence of each element.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
