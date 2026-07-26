import AppKit

/// Colours and fonts for the editor, derived from tree-sitter capture names.
///
/// The colours themselves live in a ``SyntaxPalette`` — either the built-in
/// Dark+ one or the user's own VS Code theme, imported by ``VSCodeTheme``. The
/// values are fixed rather than system colours: the centre pane's background is
/// a dark shade whatever the Mac's appearance, so a palette that followed the
/// light appearance would put dark text on a dark background.
struct SyntaxTheme: Equatable {
    let font: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont

    var palette: SyntaxPalette

    var text: NSColor { palette.foreground }
    /// A theme that names its own editor background gets it; the built-in
    /// palette names none and keeps the app's chrome instead.
    var background: NSColor { palette.background ?? AppColors.viewerBackground }
    var currentLine: NSColor { palette.currentLine }
    /// The vertical rules that mark each level of indentation.
    var indentGuide: NSColor { palette.indentGuide }
    var gutterText: NSColor { palette.lineNumber }
    var gutterBackground: NSColor { background }

    /// Line height as a multiple of the font's natural height. One means the
    /// font's own leading and nothing added: the pane is shared with two
    /// others, so the screen goes to code rather than to gaps. Settings loosens
    /// it for anyone who wants the air.
    var lineHeightMultiple: CGFloat = 1.0

    init(font: NSFont, lineHeightMultiple: CGFloat = 1.0, palette: SyntaxPalette = .darkPlus) {
        self.font = font
        self.lineHeightMultiple = lineHeightMultiple
        self.palette = palette
        self.boldFont = Self.variant(of: font, traits: .bold)
        self.italicFont = Self.variant(of: font, traits: .italic)
        self.boldItalicFont = Self.variant(of: font, traits: [.bold, .italic])
    }

    static var standard: SyntaxTheme {
        SyntaxTheme(font: .monospacedSystemFont(ofSize: 12.5, weight: .regular))
    }

    private static func variant(of font: NSFont, traits: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// Attributes for one tree-sitter capture (`keyword.function`, `string.special`, …).
    func attributes(for capture: String) -> [NSAttributedString.Key: Any] {
        let style = palette.style(for: capture) ?? SyntaxStyle(color: palette.foreground)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color]
        switch (style.bold, style.italic) {
        case (true, true): attributes[.font] = boldItalicFont
        case (true, false): attributes[.font] = boldFont
        case (false, true): attributes[.font] = italicFont
        case (false, false): break
        }
        return attributes
    }

    /// Just the colour for a capture, for views that set their own font (the
    /// diff view). Nil when the capture has no colour of its own, so the view
    /// keeps its default text colour.
    @MainActor
    static func captureColor(for capture: String) -> NSColor? {
        AppearanceSettings.shared.palette.style(for: capture)?.color
    }
}
