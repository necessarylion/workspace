import AppKit
import CodeEditSourceEditor

extension SyntaxTheme {
    /// The app's palette in the shape CodeEditSourceEditor wants.
    ///
    /// `EditorTheme` has no default of its own — every colour is required — so
    /// this exists to answer that, not to reproduce what the old highlighter
    /// did. It cannot: the package reduces every tree-sitter capture to a closed
    /// list of 21 names and then paints those with **11** colours, where the
    /// palettes here name 56. So `keyword`, `include`, `conditional`, `repeat`
    /// and `storageclass` all arrive as one colour, functions come out the same
    /// colour as variables, and anything the package does not recognise —
    /// `string.escape`, `constant`, `namespace`, `operator`, `punctuation.*`,
    /// `attribute`, the `text.*` family — is drawn as plain text.
    ///
    /// The colours are still the palette's own, so a theme picked in Settings
    /// looks like itself as far as it goes. The rest of the app is unaffected:
    /// ``SyntaxPalette`` remains the source of truth, and ``DiffHighlighter``
    /// and ``MarkdownCodeHighlighter`` keep colouring at full detail through
    /// ``TreeSitterHighlighter``. The editor is now the coarsest view of a file
    /// in the app, not the finest.
    var editorTheme: EditorTheme {
        EditorTheme(
            text: attribute(for: nil),
            // A theme that names its own caret and selection gets them; the ones
            // imported from VS Code name neither, so those are derived from the
            // foreground as they were before this existed.
            insertionPoint: palette.insertionPoint ?? palette.foreground,
            invisibles: .init(color: palette.indentGuide),
            background: background,
            lineHighlight: palette.currentLine,
            // Every palette names its own now, and the fallback is the system's
            // rather than a wash of the text colour. This is not only the selection
            // band: the editor fills the ⌘-hover box for go-to-definition with
            // this colour, and a pale grey of the foreground over a word is a word
            // you can no longer read.
            selection: palette.selection ?? .selectedTextBackgroundColor,
            keywords: attribute(for: "keyword"),
            // The package's `commands` is what it paints a call with.
            commands: attribute(for: "function"),
            types: attribute(for: "type"),
            attributes: attribute(for: "attribute"),
            variables: attribute(for: "variable"),
            values: attribute(for: "constant"),
            numbers: attribute(for: "number"),
            strings: attribute(for: "string"),
            characters: attribute(for: "character"),
            comments: attribute(for: "comment")
        )
    }

    /// One capture's colour and weight, falling back to plain text — which is
    /// also what `nil` asks for.
    private func attribute(for capture: String?) -> EditorTheme.Attribute {
        guard let capture, let style = palette.style(for: capture) else {
            return .init(color: palette.foreground)
        }
        return .init(color: style.color, bold: style.bold, italic: style.italic)
    }
}
