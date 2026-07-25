import CodeEditLanguages
import Foundation

/// One open file: its text, and everything the editor learned about it.
@MainActor
@Observable
final class OpenDocument: Identifiable {
    enum Content {
        case text(String)
        case image
        case unsupported(reason: String)
    }

    nonisolated let url: URL
    var content: Content
    var isDirty = false
    /// Contents as last read from / written to disk, used to detect edits.
    private var savedText: String

    // Editor feedback, filled in by the editor controller.
    var diagnostics: [LSP.Diagnostic] = []
    var symbols: [LSP.Symbol] = []
    var caretLine = 1
    var caretColumn = 1
    var languageServerStatus = ""
    /// Set to ask the editor to scroll to a zero-based line.
    var revealLine: Int?
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
        CodeLanguage.detectLanguageFrom(url: url)
    }

    var languageName: String {
        language.id == .plainText ? "Plain Text" : language.tsName.capitalized
    }

    nonisolated var isMarkdown: Bool { ["md", "markdown", "mdx"].contains(fileExtension) }

    var isPreviewable: Bool {
        if case .image = content { return true }
        return isMarkdown
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

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > 4_000_000 {
            self.content = .unsupported(reason: "File is larger than 4 MB.")
            self.savedText = ""
            return
        }

        if let data = try? Data(contentsOf: url), let string = String(data: data, encoding: .utf8) {
            self.content = .text(string)
            self.savedText = string
        } else {
            self.content = .unsupported(reason: "Not a UTF-8 text file.")
            self.savedText = ""
        }
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
        isDirty = false
        externalRevision += 1
    }

    // MARK: - Stats shown in the info sidebar

    var lineCount: Int {
        guard case .text(let value) = content else { return 0 }
        return value.isEmpty ? 0 : value.split(separator: "\n", omittingEmptySubsequences: false).count
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
