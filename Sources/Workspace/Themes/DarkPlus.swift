import AppKit

/// VS Code's default dark theme, and the app's own default.
extension SyntaxPalette {
    /// It names no background of its own, so the editor keeps the app's viewer
    /// colour and the pane blends with the chrome around it.
    static let darkPlus: SyntaxPalette = {
        let foreground = NSColor(hex: 0xD4_D4_D4)
        let comment = NSColor(hex: 0x6A_99_55)      // green
        let keyword = NSColor(hex: 0x56_9C_D6)      // blue
        let control = NSColor(hex: 0xC5_86_C0)      // mauve — if/for/return
        let string = NSColor(hex: 0xCE_91_78)       // terracotta
        let stringEscape = NSColor(hex: 0xD7_BA_7D) // tan
        let regex = NSColor(hex: 0xD1_69_69)        // dull red
        let number = NSColor(hex: 0xB5_CE_A8)       // pale green
        let constant = NSColor(hex: 0x4F_C1_FF)     // bright blue
        let type = NSColor(hex: 0x4E_C9_B0)         // teal
        let function = NSColor(hex: 0xDC_DC_AA)     // soft yellow
        let variable = NSColor(hex: 0x9C_DC_FE)     // pale blue
        let punctuation = NSColor(hex: 0x9D_9D_9D)

        return SyntaxPalette(
            name: "Dark+",
            foreground: foreground,
            background: nil,
            lineNumber: NSColor(hex: 0x6E_76_81),
            currentLine: NSColor(white: 1, alpha: 0.045),
            // Present, but a good deal fainter than any text on the line.
            indentGuide: NSColor(white: 1, alpha: 0.12),
            styles: [
                "comment": SyntaxStyle(color: comment),
                // Dark+ splits keywords in two: control flow is mauve,
                // everything else (declarations, modifiers, `import`) is blue.
                "keyword": SyntaxStyle(color: keyword),
                "include": SyntaxStyle(color: keyword),
                "storageclass": SyntaxStyle(color: keyword),
                "type.qualifier": SyntaxStyle(color: keyword),
                "conditional": SyntaxStyle(color: control),
                "repeat": SyntaxStyle(color: control),
                "exception": SyntaxStyle(color: control),
                "keyword.return": SyntaxStyle(color: control),
                "keyword.operator": SyntaxStyle(color: control),
                "operator": SyntaxStyle(color: foreground),
                "punctuation": SyntaxStyle(color: punctuation),
                "punctuation.bracket": SyntaxStyle(color: foreground),
                "punctuation.delimiter": SyntaxStyle(color: punctuation),
                "punctuation.special": SyntaxStyle(color: control),
                "string": SyntaxStyle(color: string),
                "character": SyntaxStyle(color: string),
                "text.literal": SyntaxStyle(color: string),
                "string.escape": SyntaxStyle(color: stringEscape),
                "string.special": SyntaxStyle(color: stringEscape),
                "string.regex": SyntaxStyle(color: regex),
                // The module a file imports reads as a path, not as data: the
                // plain string colour would lose it among the file's strings.
                "string.import": SyntaxStyle(color: type),
                "number": SyntaxStyle(color: number),
                "float": SyntaxStyle(color: number),
                "boolean": SyntaxStyle(color: keyword),
                "constant.builtin": SyntaxStyle(color: keyword),
                "constant": SyntaxStyle(color: constant),
                "constant.macro": SyntaxStyle(color: constant),
                "type": SyntaxStyle(color: type),
                "type.builtin": SyntaxStyle(color: type),
                "constructor": SyntaxStyle(color: type),
                "namespace": SyntaxStyle(color: type),
                "module": SyntaxStyle(color: type),
                "function": SyntaxStyle(color: function),
                "function.call": SyntaxStyle(color: function),
                "function.method": SyntaxStyle(color: function),
                "function.macro": SyntaxStyle(color: function),
                "method": SyntaxStyle(color: function),
                "attribute": SyntaxStyle(color: function),
                "label": SyntaxStyle(color: control),
                "variable": SyntaxStyle(color: variable),
                "variable.builtin": SyntaxStyle(color: keyword),
                "parameter": SyntaxStyle(color: variable),
                "variable.parameter": SyntaxStyle(color: variable),
                "variable.member": SyntaxStyle(color: variable),
                "property": SyntaxStyle(color: variable),
                "field": SyntaxStyle(color: variable),
                "tag": SyntaxStyle(color: keyword),
                "tag.attribute": SyntaxStyle(color: variable),
                "tag.delimiter": SyntaxStyle(color: punctuation),
                "text.title": SyntaxStyle(color: keyword, bold: true),
                "text.strong": SyntaxStyle(color: foreground, bold: true),
                "text.emphasis": SyntaxStyle(color: foreground, italic: true),
                "text.uri": SyntaxStyle(color: NSColor(hex: 0x3E_92_FF)),
                "error": SyntaxStyle(color: NSColor(hex: 0xF4_47_47), bold: true)
            ]
        )
    }()
}
