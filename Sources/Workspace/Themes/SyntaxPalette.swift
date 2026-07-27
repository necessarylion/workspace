import AppKit

/// How one tree-sitter capture is drawn.
struct SyntaxStyle: Equatable {
    var color: NSColor
    var bold = false
    var italic = false
}

/// Every colour the editor draws with, keyed by tree-sitter capture name.
///
/// The palettes themselves are in ``SyntaxPalettes``; this is only the shape
/// they share and the lookup the editor does thousands of times a screen.
struct SyntaxPalette: Equatable {
    /// What Settings calls this theme.
    var name: String
    var foreground: NSColor
    /// Nil leaves the editor on the app's own viewer background, so the pane
    /// blends with the chrome instead of naming a colour of its own.
    var background: NSColor?
    var lineNumber: NSColor
    var currentLine: NSColor
    var indentGuide: NSColor
    /// The selection band, and the caret. Both optional because they were added
    /// for ``SyntaxPalette/codeEdit``, which is ported from a theme format that
    /// names them; the palettes imported from VS Code do not, and fall back to
    /// something derived from the foreground — see ``SyntaxTheme/editorTheme``.
    var selection: NSColor?
    var insertionPoint: NSColor?
    var styles: [String: SyntaxStyle]

    /// Captures are matched longest-first: `keyword.return` falls back to
    /// `keyword`, which is how tree-sitter highlight themes are meant to work.
    func style(for capture: String) -> SyntaxStyle? {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let style = styles[parts.joined(separator: ".")] { return style }
            parts.removeLast()
        }
        return nil
    }
}
