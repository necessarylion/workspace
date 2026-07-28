import CodeEditLanguages
import Foundation

/// One open file: its text, and everything the editor learned about it.
@MainActor
@Observable
final class OpenDocument: Identifiable {
    enum Content {
        case text(String)
        case image
        case pdf
        case unsupported(reason: String)
    }

    nonisolated let url: URL
    var content: Content
    var isDirty = false
    /// Contents as last read from / written to disk, used to detect edits.
    private var savedText: String

    /// Why this file is more than the editing stack should take on in full, or
    /// nil for an ordinary one. See ``largeFileNote(for:)``.
    private(set) var largeFileNote: String?
    var isLargeFile: Bool { largeFileNote != nil }

    // Editor feedback, filled in by the editor controller.
    var diagnostics: [LSP.Diagnostic] = []
    var symbols: [LSP.Symbol] = []
    var caretLine = 1
    var caretColumn = 1
    var languageServerStatus = ""
    /// Set to ask the editor to scroll to a zero-based line, and optionally to a
    /// zero-based column on it.
    ///
    /// Read twice, and it has to be: by the editor's `onChange` while the file is
    /// already open, and once as the editor is built — `WorkspaceStore.openFile`
    /// sets this on a document it has only just made, so for a file that was not
    /// already open the value is there from the first render and never changes.
    var revealLine: Int?
    var revealColumn: Int?

    /// The pending reveal, cleared as it is handed over, so whichever of the two
    /// readers gets there first is the only one that acts on it.
    ///
    /// Zero-based going in, one-based coming out — the editor counts from one.
    func takePendingReveal() -> (line: Int, column: Int)? {
        guard let line = revealLine else { return nil }
        let column = revealColumn ?? 0
        revealLine = nil
        revealColumn = nil
        return (line + 1, column + 1)
    }
    /// Bumped when the text was replaced from outside the editor.
    private(set) var externalRevision = 0
    /// Bumped on save, so the editor can tell the language server.
    private(set) var saveRevision = 0

    nonisolated var id: URL { url }
    nonisolated var name: String { url.lastPathComponent }
    nonisolated var fileExtension: String { url.pathExtension.lowercased() }

    var text: String {
        get {
            if case .text(let value) = content { return value }
            return ""
        }
        set {
            content = .text(newValue)
            isDirty = newValue != savedText
            externalRevision += 1
        }
    }

    /// The editor already holds this text — don't ask it to reload.
    func applyEditorText(_ newValue: String) {
        content = .text(newValue)
        isDirty = newValue != savedText
    }

    var language: CodeLanguage {
        CodeLanguage.forFile(url: url)
    }

    var languageName: String {
        language.id == .plainText ? "Plain Text" : language.tsName.capitalized
    }

    nonisolated var isMarkdown: Bool { ["md", "markdown", "mdx"].contains(fileExtension) }

    nonisolated var isPDF: Bool { fileExtension == "pdf" }

    /// A draw.io diagram. `.drawio` and `.dio` say so themselves; for the other
    /// shapes draw.io writes — plain `.xml`, and the `.svg` / `.html` it exports
    /// with the model kept inside — the `<mxfile>` near the top of the text is
    /// what tells them apart from an ordinary file of that kind.
    var isDrawio: Bool {
        if ["drawio", "dio"].contains(fileExtension) { return true }
        guard ["xml", "svg", "html"].contains(fileExtension),
              case .text(let value) = content
        else { return false }
        return value.prefix(4096).contains("mxfile")
    }

    var isPreviewable: Bool {
        switch content {
        case .image, .pdf: true
        default: isMarkdown || isDrawio
        }
    }

    var errorCount: Int { diagnostics.filter { $0.level == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.level == .warning }.count }

    init(url: URL) {
        self.url = url

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "bmp", "icns"]
        if imageExtensions.contains(url.pathExtension.lowercased()) {
            self.content = .image
            self.savedText = ""
            return
        }

        // Ahead of the size check below: PDFKit reads a document page by page,
        // so a big PDF costs no more to open than a small one — and a PDF worth
        // reading is routinely past the limit that guards the text editor.
        if url.pathExtension.lowercased() == "pdf" {
            self.content = .pdf
            self.savedText = ""
            return
        }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 4_000_000 {
            self.content = .unsupported(reason: "File is larger than 4 MB.")
            self.savedText = ""
            return
        }

        if let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) {
            self.content = .text(string)
            self.savedText = string
            self.largeFileNote = Self.largeFileNote(for: string)
        } else {
            self.content = .unsupported(reason: "Not a UTF-8 text file.")
            self.savedText = ""
        }
    }

    /// Why a text file cannot be given the full editing stack, or nil.
    ///
    /// Two shapes are out of reach, and the second matters as much as the first:
    /// sheer length, and a single very long line. A minified bundle is both —
    /// `mermaid.min.js` is 3.5 MB on one 324,000-character line, comfortably
    /// under the 4 MB ceiling above and still enough to take the window down.
    /// Unwrapped, that one line asks AppKit for a text view two million points
    /// wide and lays the whole document out before it can know that width; on
    /// top of which tree-sitter parses the bundle and the language server is
    /// handed it, both on the main thread, before the first frame is drawn.
    ///
    /// Measured in UTF-8 bytes, which `String` already has: a byte count is at
    /// least the character count, so nothing pathological slips through, and it
    /// costs no walk over the text to ask for.
    private static func largeFileNote(for text: String) -> String? {
        let bytes = text.utf8
        guard bytes.count <= 1_000_000 else {
            return "Large file — highlighting, code intelligence and editing are off."
        }
        var run = 0
        for byte in bytes {
            if byte == 0x0A {
                run = 0
                continue
            }
            run += 1
            if run > 5_000 {
                return "Very long lines — highlighting, code intelligence and editing are off."
            }
        }
        return nil
    }

    func save() throws {
        guard case .text(let value) = content else { return }
        try value.write(to: url, atomically: true, encoding: .utf8)
        savedText = value
        isDirty = false
        saveRevision += 1
    }

    func reloadFromDisk() {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8) else { return }
        savedText = string
        content = .text(string)
        largeFileNote = Self.largeFileNote(for: string)
        isDirty = false
        externalRevision += 1
    }

    // MARK: - Stats shown in the info sidebar

    /// Counted rather than split: the status bar asks for this on every redraw,
    /// and splitting a multi-megabyte file allocates a substring per line each
    /// time it does.
    var lineCount: Int {
        guard case .text(let value) = content, !value.isEmpty else { return 0 }
        return value.utf8.reduce(1) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    var wordCount: Int {
        guard case .text(let value) = content else { return 0 }
        return value.split(whereSeparator: \.isWhitespace).count
    }

    var characterCount: Int {
        guard case .text(let value) = content else { return 0 }
        return value.count
    }

    /// Markdown headings, used when no language server supplies symbols.
    var outline: [(level: Int, title: String)] {
        guard isMarkdown, case .text(let value) = content else { return [] }
        return value.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            guard level <= 6 else { return nil }
            let title = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return nil }
            return (level, title)
        }
    }
}
