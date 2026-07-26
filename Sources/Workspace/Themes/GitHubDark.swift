import AppKit

/// GitHub's own dark theme.
///
/// Ported from the `GitHub Dark Default` file in GitHub's VS Code extension —
/// the one github.com itself reads as dark, and the darkest background of the
/// four here.
extension SyntaxPalette {
    static let gitHubDark = SyntaxPalette(
        name: "GitHub Dark",
        foreground: NSColor(hex: 0xE6_ED_F3),
        background: NSColor(hex: 0x0D_11_17),
        lineNumber: NSColor(hex: 0x6E_76_81),
        currentLine: NSColor(hex: 0x6E_76_81, alpha: 0.102),
        indentGuide: NSColor(hex: 0xE6_ED_F3, alpha: 0.122),
        styles: [
            "attribute": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "boolean": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "character": SyntaxStyle(color: NSColor(hex: 0xA5_D6_FF)),
            "comment": SyntaxStyle(color: NSColor(hex: 0x8B_94_9E)),
            "conditional": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "constant": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "constant.builtin": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "constant.macro": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "constructor": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "exception": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "field": SyntaxStyle(color: NSColor(hex: 0xE6_ED_F3)),
            "float": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "function": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "function.call": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "function.macro": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "function.method": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "include": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "keyword": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "keyword.function": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "keyword.operator": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "keyword.return": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "label": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "method": SyntaxStyle(color: NSColor(hex: 0xD2_A8_FF)),
            "module": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "namespace": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "number": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "operator": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "parameter": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "property": SyntaxStyle(color: NSColor(hex: 0xE6_ED_F3)),
            "repeat": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "storageclass": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "string": SyntaxStyle(color: NSColor(hex: 0xA5_D6_FF)),
            "string.escape": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "string.import": SyntaxStyle(color: NSColor(hex: 0xA5_D6_FF)),
            "string.regex": SyntaxStyle(color: NSColor(hex: 0xA5_D6_FF)),
            "string.special": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "tag": SyntaxStyle(color: NSColor(hex: 0x7E_E7_87)),
            "tag.attribute": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "text.emphasis": SyntaxStyle(color: NSColor(hex: 0xE6_ED_F3), italic: true),
            "text.literal": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "text.strong": SyntaxStyle(color: NSColor(hex: 0xE6_ED_F3), bold: true),
            "text.title": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF), bold: true),
            "type": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "type.builtin": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "type.qualifier": SyntaxStyle(color: NSColor(hex: 0xFF_7B_72)),
            "variable": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57)),
            "variable.builtin": SyntaxStyle(color: NSColor(hex: 0x79_C0_FF)),
            "variable.member": SyntaxStyle(color: NSColor(hex: 0xE6_ED_F3)),
            "variable.parameter": SyntaxStyle(color: NSColor(hex: 0xFF_A6_57))
        ]
    )
}
