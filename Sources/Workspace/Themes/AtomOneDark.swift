import AppKit

/// Atom's One Dark, the theme most editors ended up copying.
///
/// Ported from akamud's VS Code port of it, which is the one people install
/// when they say "One Dark".
extension SyntaxPalette {
    static let atomOneDark = SyntaxPalette(
        name: "Atom One Dark",
        foreground: NSColor(hex: 0xAB_B2_BF),
        background: NSColor(hex: 0x28_2C_34),
        lineNumber: NSColor(hex: 0x63_6D_83),
        currentLine: NSColor(hex: 0x99_BB_FF, alpha: 0.039),
        indentGuide: NSColor(hex: 0xAB_B2_BF, alpha: 0.149),
        styles: [
            "attribute": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "boolean": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66)),
            "character": SyntaxStyle(color: NSColor(hex: 0x98_C3_79)),
            "comment": SyntaxStyle(color: NSColor(hex: 0x5C_63_70), italic: true),
            "conditional": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "constant": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "constant.builtin": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66)),
            "constant.macro": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "constructor": SyntaxStyle(color: NSColor(hex: 0xE5_C0_7B)),
            "exception": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "field": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "float": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66)),
            "function": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "function.call": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "function.macro": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "function.method": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "include": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "keyword": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "keyword.function": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "keyword.operator": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "keyword.return": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "label": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "method": SyntaxStyle(color: NSColor(hex: 0x61_AF_EF)),
            "module": SyntaxStyle(color: NSColor(hex: 0xE5_C0_7B)),
            "namespace": SyntaxStyle(color: NSColor(hex: 0xE5_C0_7B)),
            "number": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66)),
            "operator": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "parameter": SyntaxStyle(color: NSColor(hex: 0xAB_B2_BF)),
            "property": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "repeat": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "storageclass": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "string": SyntaxStyle(color: NSColor(hex: 0x98_C3_79)),
            "string.escape": SyntaxStyle(color: NSColor(hex: 0x56_B6_C2)),
            "string.import": SyntaxStyle(color: NSColor(hex: 0x98_C3_79)),
            "string.regex": SyntaxStyle(color: NSColor(hex: 0x56_B6_C2)),
            "string.special": SyntaxStyle(color: NSColor(hex: 0x56_B6_C2)),
            "tag": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "tag.attribute": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66)),
            "text.emphasis": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD), italic: true),
            "text.literal": SyntaxStyle(color: NSColor(hex: 0x98_C3_79)),
            "text.strong": SyntaxStyle(color: NSColor(hex: 0xD1_9A_66), bold: true),
            "text.title": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "type": SyntaxStyle(color: NSColor(hex: 0xE5_C0_7B)),
            "type.builtin": SyntaxStyle(color: NSColor(hex: 0x56_B6_C2)),
            "type.qualifier": SyntaxStyle(color: NSColor(hex: 0xC6_78_DD)),
            "variable": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "variable.builtin": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "variable.member": SyntaxStyle(color: NSColor(hex: 0xE0_6C_75)),
            "variable.parameter": SyntaxStyle(color: NSColor(hex: 0xAB_B2_BF))
        ]
    )
}
