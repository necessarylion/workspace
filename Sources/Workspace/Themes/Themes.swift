import AppKit

/// Every theme the app ships with.
///
/// To add one: run `Scripts/import-vscode-theme.swift "Some Theme"`, drop what
/// it prints into a file of its own in this folder, and add it to the list
/// below. The order is the order Settings shows, and the first is the default.
/// Not every theme here came from VS Code — ``SyntaxPalette/codeEdit`` is ported
/// by hand from a `.cetheme` file, which names its colours quite differently.
extension SyntaxPalette {
    static let all: [SyntaxPalette] = [adonisEclipse, codeEdit, gitHubDark, atomOneDark, darkPlus]

    /// The theme saved under `name`, or the default when it is gone — a theme
    /// can be renamed or dropped between versions.
    static func named(_ name: String?) -> SyntaxPalette {
        all.first { $0.name == name } ?? all[0]
    }
}
