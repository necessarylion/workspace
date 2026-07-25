import AppKit

/// Colours for the editor, derived from tree-sitter capture names.
///
/// The text colours are system colours, so the editor follows the system
/// light/dark appearance without shipping two palettes. Only the background
/// is fixed: it has to match the rest of the centre pane.
struct SyntaxTheme {
    let font: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let boldItalicFont: NSFont

    var text: NSColor { .textColor }
    var background: NSColor { AppColors.viewerBackground }
    var currentLine: NSColor { .controlAccentColor.withAlphaComponent(0.09) }
    /// The vertical rules that mark each level of indentation: present, but a
    /// good deal fainter than any text on the line.
    var indentGuide: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.15)
                : NSColor(white: 0, alpha: 0.13)
        }
    }
    var gutterText: NSColor { .tertiaryLabelColor }
    var gutterBackground: NSColor { AppColors.viewerBackground }

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
        return Style(color: .textColor)
    }

    private static func namedStyle(_ name: String) -> Style? {
        switch name {
        case "comment":
            Style(color: .systemGray, italic: true)
        case "keyword", "conditional", "repeat", "include", "keyword.return":
            Style(color: .systemPink, bold: true)
        case "operator":
            Style(color: .secondaryLabelColor)
        case "punctuation", "punctuation.delimiter":
            Style(color: .tertiaryLabelColor)
        case "punctuation.bracket":
            Style(color: .secondaryLabelColor)
        case "punctuation.special":
            Style(color: .systemPink)
        case "string", "character", "text.literal":
            Style(color: .systemRed)
        case "string.escape", "string.special":
            Style(color: .systemOrange)
        // The module a file imports reads as a path, not as data: green sets it
        // apart from every other string in the file.
        case "string.import":
            Style(color: .systemGreen)
        case "number", "float", "boolean", "constant":
            Style(color: .systemOrange)
        case "type", "constructor", "namespace", "module":
            Style(color: .systemTeal)
        case "function", "method":
            Style(color: .systemBlue)
        case "function.macro", "attribute", "label":
            Style(color: .systemIndigo)
        case "property", "field":
            Style(color: .systemPurple)
        case "variable", "parameter":
            Style(color: .textColor)
        case "variable.builtin":
            Style(color: .systemPink)
        case "tag":
            Style(color: .systemPink)
        case "tag.attribute":
            Style(color: .systemPurple)
        case "text.title", "text.strong":
            Style(color: .textColor, bold: true)
        case "text.emphasis":
            Style(color: .textColor, italic: true)
        case "text.uri":
            Style(color: .linkColor)
        case "error":
            Style(color: .systemRed, bold: true)
        default:
            nil
        }
    }
}
