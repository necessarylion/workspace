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
    /// The region already coloured, so plain scrolling does no work until the
    /// viewport leaves it.
    private var highlightedRange = NSRange(location: 0, length: 0)

    private var syncTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
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
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = theme.background

        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.theme = theme
        self.ruler = ruler
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.onCommandClick = { [weak self] offset in self?.jumpToDefinition(at: offset) }
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

    override func viewDidAppear() {
        super.viewDidAppear()
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
        language = CodeLanguage.detectLanguageFrom(url: url)

        isApplyingExternalText = true
        textView.string = text
        isApplyingExternalText = false

        if let highlighter {
            highlighter.setLanguage(language)
            highlighter.setText(text)
        } else {
            highlighter = TreeSitterHighlighter(language: language)
            highlighter?.setText(text)
        }

        applyBaseAttributes()
        ruler.invalidateLines()
        ruler.updateThickness()
        highlightVisible()
        reportCaret()

        attachService(text: text)
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
        highlightVisible()
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

    // MARK: - Language server

    private var uri: String { fileURL?.absoluteString ?? "" }

    private func attachService(text: String) {
        guard let fileURL, let projectRoot,
              let service = LanguageServerRegistry.shared.service(for: language, root: projectRoot) else {
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

        // setAttributes just wiped the underlines in `target`; put back only
        // the ones that fall inside it.
        applyDiagnosticUnderlines(in: target)
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
        guard let service, let fileURL, service.status.isHealthy else { return }
        let target = position(for: offset)
        Task { [weak self] in
            let locations = await service.definitions(
                uri: fileURL.absoluteString,
                position: target
            )
            guard let self, let target = locations.first, let url = target.fileURL else { return }
            if url == fileURL {
                reveal(line: target.range.start.line)
            } else {
                onOpenLocation?(url, target.range.start.line)
            }
        }
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
