import AppKit

/// Colours for the editor, derived from tree-sitter capture names.
///
/// The palette is VS Code's default dark theme (Dark+). The values are fixed
/// rather than system colours: the centre pane's background is a fixed dark
/// shade, so a palette that followed the light appearance would put dark text
/// on a dark background.
struct SyntaxTheme {
    let font: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont

    var text: NSColor { Palette.foreground }
    var background: NSColor { AppColors.viewerBackground }
    var currentLine: NSColor { NSColor(white: 1, alpha: 0.045) }
    /// The vertical rules that mark each level of indentation: present, but a
    /// good deal fainter than any text on the line.
    var indentGuide: NSColor { NSColor(white: 1, alpha: 0.12) }
    var gutterText: NSColor { Palette.lineNumber }
    var gutterBackground: NSColor { AppColors.viewerBackground }

    /// VS Code Dark+ token colours, by their role in that theme.
    private enum Palette {
        static let foreground = NSColor(hex: 0xD4_D4_D4)
        static let lineNumber = NSColor(hex: 0x6E_76_81)
        static let comment = NSColor(hex: 0x6A_99_55)      // green
        static let keyword = NSColor(hex: 0x56_9C_D6)      // blue
        static let control = NSColor(hex: 0xC5_86_C0)      // mauve — if/for/return
        static let string = NSColor(hex: 0xCE_91_78)       // terracotta
        static let stringEscape = NSColor(hex: 0xD7_BA_7D) // tan
        static let regex = NSColor(hex: 0xD1_69_69)        // dull red
        static let number = NSColor(hex: 0xB5_CE_A8)       // pale green
        static let constant = NSColor(hex: 0x4F_C1_FF)     // bright blue
        static let type = NSColor(hex: 0x4E_C9_B0)         // teal
        static let function = NSColor(hex: 0xDC_DC_AA)     // soft yellow
        static let variable = NSColor(hex: 0x9C_DC_FE)     // pale blue
        static let punctuation = NSColor(hex: 0x9D_9D_9D)
        static let error = NSColor(hex: 0xF4_47_47)
        static let link = NSColor(hex: 0x3E_92_FF)
    }

    /// Line height as a multiple of the font's natural height.
    var lineHeightMultiple: CGFloat = 1.35

    init(font: NSFont) {
        self.font = font
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
        let style = Self.style(for: capture)
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: style.color]
        switch (style.bold, style.italic) {
        case (true, true): attributes[.font] = boldItalicFont
        case (true, false): attributes[.font] = boldFont
        case (false, true): attributes[.font] = italicFont
        case (false, false): break
        }
        return attributes
    }

    /// Just the colour for a capture, for views that set their own font
    /// (the diff view). Nil when the capture has no colour of its own.
    static func captureColor(for capture: String) -> NSColor? {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let style = namedStyle(parts.joined(separator: ".")) {
                return style.color
            }
            parts.removeLast()
        }
        return nil
    }

    private struct Style {
        var color: NSColor
        var bold = false
        var italic = false
    }

    /// Captures are matched longest-first: `keyword.return` falls back to
    /// `keyword`, which is how tree-sitter highlight themes are meant to work.
    private static func style(for capture: String) -> Style {
        var parts = capture.split(separator: ".").map(String.init)
        while !parts.isEmpty {
            if let style = namedStyle(parts.joined(separator: ".")) {
                return style
            }
            parts.removeLast()
        }
        return Style(color: Palette.foreground)
    }

    private static func namedStyle(_ name: String) -> Style? {
        switch name {
        case "comment":
            Style(color: Palette.comment)
        // Dark+ splits keywords in two: control flow is mauve, everything else
        // (declarations, modifiers, `import`) is blue.
        case "keyword", "include", "storageclass", "type.qualifier":
            Style(color: Palette.keyword)
        case "conditional", "repeat", "exception", "keyword.return", "keyword.operator":
            Style(color: Palette.control)
        case "operator", "punctuation.bracket":
            Style(color: Palette.foreground)
        case "punctuation", "punctuation.delimiter":
            Style(color: Palette.punctuation)
        case "punctuation.special":
            Style(color: Palette.control)
        case "string", "character", "text.literal":
            Style(color: Palette.string)
        case "string.escape", "string.special":
            Style(color: Palette.stringEscape)
        case "string.regex":
            Style(color: Palette.regex)
        // The module a file imports reads as a path, not as data: the plain
        // string colour would lose it among the file's real strings.
        case "string.import":
            Style(color: Palette.type)
        case "number", "float":
            Style(color: Palette.number)
        case "boolean", "constant.builtin":
            Style(color: Palette.keyword)
        case "constant", "constant.macro":
            Style(color: Palette.constant)
        case "type", "constructor", "namespace", "module", "type.builtin":
            Style(color: Palette.type)
        case "function", "method", "function.macro", "attribute":
            Style(color: Palette.function)
        case "label":
            Style(color: Palette.control)
        case "variable", "parameter", "property", "field":
            Style(color: Palette.variable)
        case "variable.builtin":
            Style(color: Palette.keyword)
        case "tag":
            Style(color: Palette.keyword)
        case "tag.attribute":
            Style(color: Palette.variable)
        case "tag.delimiter":
            Style(color: Palette.punctuation)
        case "text.title":
            Style(color: Palette.keyword, bold: true)
        case "text.strong":
            Style(color: Palette.foreground, bold: true)
        case "text.emphasis":
            Style(color: Palette.foreground, italic: true)
        case "text.uri":
            Style(color: Palette.link)
        case "error":
            Style(color: Palette.error, bold: true)
        default:
            nil
        }
    }
}
