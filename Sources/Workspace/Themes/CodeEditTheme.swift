import AppKit

/// CodeEdit's own default dark theme, which is Xcode's.
///
/// Ported from `DefaultThemes/Default (Dark).cetheme` in
/// https://github.com/CodeEditApp/CodeEdit — MIT, © CodeEdit. That file names
/// eleven colours for code and five for the editor around it; every value below
/// is one of them, unchanged.
///
/// Eleven names do not divide into the fifty-six captures a palette here can
/// colour, so the spread is by what the colours *mean* in Xcode, which is where
/// they come from: one cyan for type names and a darker one for instance
/// variables, teal for functions and methods, purple for macros and other
/// preprocessor values, khaki shared by numbers and character escapes.
///
/// A note on where this shows. The editor is CodeEditSourceEditor, and it
/// reduces every capture to eleven colours of its own accord — so there the
/// grouping below is mostly re-flattened, and the result is close to what
/// CodeEdit itself draws. The full detail is still used, at full detail, by the
/// diff view and by fenced code blocks in Markdown, which colour through
/// ``TreeSitterHighlighter`` rather than through the editor.
extension SyntaxPalette {
    static let codeEdit: SyntaxPalette = {
        let text = NSColor(rgb: 0xFF_FF_FF)
        let comment = NSColor(rgb: 0x7F_8C_98)      // slate grey
        let keyword = NSColor(rgb: 0xFF_7A_B2)      // pink
        let string = NSColor(rgb: 0xFF_81_70)        // salmon
        let character = NSColor(rgb: 0xD9_C9_7C)     // khaki — also numbers
        let type = NSColor(rgb: 0x6B_DF_FF)          // light cyan
        let variable = NSColor(rgb: 0x4E_B0_CC)      // darker cyan
        let command = NSColor(rgb: 0x78_C2_B3)       // teal — functions, methods
        let value = NSColor(rgb: 0xB2_81_EB)         // purple — macros, constants
        let attribute = NSColor(rgb: 0xCC_97_68)     // tan

        return SyntaxPalette(
            name: "CodeEditTheme",
            foreground: text,
            // Named, unlike Dark+: this theme has a background of its own and
            // the pane takes it rather than the app's viewer colour.
            background: NSColor(rgb: 0x29_2A_30),
            // CodeEdit draws its gutter with the text colour at 35%, so the line
            // numbers are that rather than a colour the theme file names.
            lineNumber: text.withAlphaComponent(0.35),
            currentLine: NSColor(rgb: 0x2F_32_39),
            // The theme's `invisibles`, which is what it also rules columns with.
            indentGuide: NSColor(rgb: 0x53_60_6E),
            selection: NSColor(rgb: 0x64_6F_83),
            insertionPoint: NSColor(rgb: 0x00_7A_FF),
            styles: [
                "comment": SyntaxStyle(color: comment),

                // Bold, as the theme file asks for on `keywords`. Xcode makes no
                // split between control flow and declarations — one pink for
                // every reserved word — so this stays flat where Dark+ divides.
                "keyword": SyntaxStyle(color: keyword, bold: true),
                "include": SyntaxStyle(color: keyword, bold: true),
                "storageclass": SyntaxStyle(color: keyword, bold: true),
                "conditional": SyntaxStyle(color: keyword, bold: true),
                "repeat": SyntaxStyle(color: keyword, bold: true),
                "exception": SyntaxStyle(color: keyword, bold: true),
                "keyword.return": SyntaxStyle(color: keyword, bold: true),
                "keyword.operator": SyntaxStyle(color: keyword, bold: true),
                "keyword.function": SyntaxStyle(color: keyword, bold: true),
                "type.qualifier": SyntaxStyle(color: keyword, bold: true),
                "boolean": SyntaxStyle(color: keyword, bold: true),
                "constant.builtin": SyntaxStyle(color: keyword, bold: true),
                "variable.builtin": SyntaxStyle(color: keyword, bold: true),
                "tag": SyntaxStyle(color: keyword, bold: true),

                "string": SyntaxStyle(color: string),
                "text.literal": SyntaxStyle(color: string),
                // The theme's own `characters`, which in Xcode covers a
                // character literal and the escapes inside a string alike.
                "character": SyntaxStyle(color: character),
                "string.escape": SyntaxStyle(color: character),
                "string.special": SyntaxStyle(color: character),
                "string.regex": SyntaxStyle(color: character),
                // An import's path reads as a path rather than as data — the
                // string colour would lose it among the file's own strings.
                "string.import": SyntaxStyle(color: type),

                "number": SyntaxStyle(color: character),
                "float": SyntaxStyle(color: character),

                "type": SyntaxStyle(color: type),
                "type.builtin": SyntaxStyle(color: type),
                "constructor": SyntaxStyle(color: type),
                "namespace": SyntaxStyle(color: type),
                "module": SyntaxStyle(color: type),

                // `commands` in the theme file: Xcode's "other function and
                // method names".
                "function": SyntaxStyle(color: command),
                "function.call": SyntaxStyle(color: command),
                "function.method": SyntaxStyle(color: command),
                "method": SyntaxStyle(color: command),

                // `values`: what Xcode paints macros and other preprocessor
                // results with, so the macro-shaped captures go here too.
                "constant": SyntaxStyle(color: value),
                "constant.macro": SyntaxStyle(color: value),
                "function.macro": SyntaxStyle(color: value),
                "label": SyntaxStyle(color: value),

                "variable": SyntaxStyle(color: variable),
                "parameter": SyntaxStyle(color: variable),
                "variable.parameter": SyntaxStyle(color: variable),
                "variable.member": SyntaxStyle(color: variable),
                "property": SyntaxStyle(color: variable),
                "field": SyntaxStyle(color: variable),

                "attribute": SyntaxStyle(color: attribute),
                "tag.attribute": SyntaxStyle(color: attribute),

                // Xcode leaves operators and punctuation the plain text colour
                // rather than dimming them the way Dark+ does.
                "operator": SyntaxStyle(color: text),
                "punctuation": SyntaxStyle(color: text),
                "punctuation.bracket": SyntaxStyle(color: text),
                "punctuation.delimiter": SyntaxStyle(color: text),
                "punctuation.special": SyntaxStyle(color: keyword),

                // Markdown, which the theme file says nothing about — these
                // follow the same colours by role, so a `.md` file is not left
                // uniformly white.
                "text.title": SyntaxStyle(color: keyword, bold: true),
                "text.strong": SyntaxStyle(color: text, bold: true),
                "text.emphasis": SyntaxStyle(color: text, italic: true),
                "text.uri": SyntaxStyle(color: variable),

                "error": SyntaxStyle(color: NSColor(rgb: 0xFF_81_70), bold: true)
            ]
        )
    }()
}
