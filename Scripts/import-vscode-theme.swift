#!/usr/bin/env swift
import AppKit

// Turns a VS Code colour theme into a `SyntaxPalette` literal, ready to become
// a file of its own in Sources/Workspace/Themes/.
//
//     swift Scripts/import-vscode-theme.swift "Adonis Eclipse"
//     swift Scripts/import-vscode-theme.swift path/to/dark.json "GitHub Dark"
//
// The second form is for a theme that is not installed here: unpack the
// extension (a .vsix is a zip) and point at the theme file inside it.
//
// Then add it to the list in Themes/Themes.swift, which is what Settings shows.
//
// With no argument it reads whatever theme your own VS Code is set to. The app
// itself does not do this at runtime on purpose: colours read from one Mac's
// VS Code would be missing on any other, so a theme is ported once, by hand,
// and shipped with the app.
//
// The scope table below is the interesting part — our highlighter thinks in
// tree-sitter capture names, a VS Code theme is written against TextMate
// scopes, and neither knows about the other.

struct SyntaxStyle {
    var color: NSColor
    var bold = false
    var italic = false
}

struct SyntaxPalette {
    var name: String
    var foreground: NSColor
    var background: NSColor?
    var lineNumber: NSColor
    var currentLine: NSColor
    var indentGuide: NSColor
    var styles: [String: SyntaxStyle]
}

enum VSCodeTheme {
    /// A theme that was found, ready for the editor.
    struct Loaded {
        /// The name as VS Code shows it — "Adonis Eclipse", "Monokai", …
        let name: String
        /// Which editor's settings named it, for Settings to say so.
        let source: String
        let palette: SyntaxPalette
    }

    /// Reads the current theme, or nil when there is no VS Code, no theme
    /// setting, or no extension providing the named theme.
    static func load(named requested: String? = nil) -> Loaded? {
        guard let (name, source) = requested.map({ ($0, "the command line") }) ?? currentThemeName() else {
            return nil
        }
        guard let file = themeFile(named: name) else { return nil }
        guard let parsed = parse(file) else { return nil }
        return Loaded(name: name, source: source, palette: palette(named: name, from: parsed))
    }

    /// A theme file straight off disk, for one that is not installed here.
    static func load(file: URL, named name: String?) -> Loaded? {
        guard let parsed = parse(file) else { return nil }
        let title = name
            ?? (object(at: file)?["name"] as? String)
            ?? file.deletingPathExtension().lastPathComponent
        return Loaded(name: title, source: file.lastPathComponent, palette: palette(named: title, from: parsed))
    }

    // MARK: - Finding the theme

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Where each VS Code-shaped editor keeps its user settings, most standard
    /// first. The first one that names a theme wins.
    private static var settingsFiles: [(app: String, url: URL)] {
        let support = home.appending(path: "Library/Application Support")
        return [
            ("VS Code", support.appending(path: "Code/User/settings.json")),
            ("VS Code Insiders", support.appending(path: "Code - Insiders/User/settings.json")),
            ("VSCodium", support.appending(path: "VSCodium/User/settings.json")),
            ("Cursor", support.appending(path: "Cursor/User/settings.json"))
        ]
    }

    /// Where extensions are installed, plus the themes VS Code itself ships.
    private static var extensionRoots: [URL] {
        var roots = [
            home.appending(path: ".vscode/extensions"),
            home.appending(path: ".vscode-insiders/extensions"),
            home.appending(path: ".vscode-oss/extensions"),
            home.appending(path: ".cursor/extensions")
        ]
        for app in ["Visual Studio Code", "Visual Studio Code - Insiders", "VSCodium", "Cursor"] {
            roots.append(URL(filePath: "/Applications/\(app).app/Contents/Resources/app/extensions"))
        }
        return roots
    }

    private static func currentThemeName() -> (name: String, source: String)? {
        for entry in settingsFiles {
            guard let settings = object(at: entry.url),
                  let name = settings["workbench.colorTheme"] as? String else { continue }
            return (name, entry.app)
        }
        return nil
    }

    /// The theme file an extension contributes under this name. Extensions
    /// declare themes by `label` (what the picker shows) or by `id`.
    private static func themeFile(named name: String) -> URL? {
        let manager = FileManager.default
        for root in extensionRoots {
            guard let extensions = try? manager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            ) else { continue }

            for folder in extensions {
                let manifest = folder.appending(path: "package.json")
                guard let package = object(at: manifest),
                      let contributes = package["contributes"] as? [String: Any],
                      let themes = contributes["themes"] as? [[String: Any]] else { continue }

                for theme in themes {
                    let label = theme["label"] as? String
                    let id = theme["id"] as? String
                    guard label == name || id == name, let path = theme["path"] as? String else {
                        continue
                    }
                    return URL(filePath: path, relativeTo: folder).standardizedFileURL
                }
            }
        }
        return nil
    }

    // MARK: - Reading the theme file

    /// A theme's own colours plus every rule it inherited, base first.
    private struct Parsed {
        var colors: [String: String] = [:]
        var rules: [Rule] = []
    }

    private struct Rule {
        var scopes: [String]
        var color: String?
        var fontStyle: String?
    }

    /// Follows `include`, which is how themes share a base — the including
    /// file's own values win, so it is read last.
    private static func parse(_ url: URL, depth: Int = 0) -> Parsed? {
        guard depth < 8, let theme = object(at: url) else { return nil }
        var parsed = Parsed()

        if let include = theme["include"] as? String,
           let base = parse(URL(filePath: include, relativeTo: url.deletingLastPathComponent()), depth: depth + 1) {
            parsed = base
        }

        if let colors = theme["colors"] as? [String: Any] {
            for (key, value) in colors {
                if let hex = value as? String { parsed.colors[key] = hex }
            }
        }

        for entry in theme["tokenColors"] as? [[String: Any]] ?? [] {
            let scopes: [String]
            switch entry["scope"] {
            case let list as [String]: scopes = list
            // One string can still hold several scopes, comma separated.
            case let single as String: scopes = single.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            default: continue
            }
            let settings = entry["settings"] as? [String: Any] ?? [:]
            parsed.rules.append(
                Rule(
                    scopes: scopes,
                    color: settings["foreground"] as? String,
                    fontStyle: settings["fontStyle"] as? String
                )
            )
        }

        return parsed
    }

    // MARK: - TextMate scopes → tree-sitter captures

    /// What each capture is called in a TextMate grammar, most specific first.
    ///
    /// This is the whole translation: our highlighter thinks in tree-sitter
    /// capture names, a VS Code theme is written against TextMate scopes, and
    /// neither side knows about the other. Where a theme colours only a narrow
    /// scope (`punctuation.separator.comma` rather than `punctuation`) the
    /// narrow one has to be asked for by name, which is why several captures
    /// list more than one candidate.
    private static let scopeTable: [(capture: String, scopes: [String])] = [
        ("comment", ["comment"]),
        ("keyword", ["keyword"]),
        ("include", ["keyword.control.import", "keyword.control"]),
        ("storageclass", ["storage.modifier", "storage"]),
        ("type.qualifier", ["storage.modifier", "storage"]),
        ("conditional", ["keyword.control.conditional", "keyword.control"]),
        ("repeat", ["keyword.control.loop", "keyword.control"]),
        ("exception", ["keyword.control.exception", "keyword.control"]),
        ("keyword.return", ["keyword.control.flow", "keyword.control"]),
        ("keyword.function", ["storage.type.function", "storage.type", "keyword"]),
        ("keyword.operator", ["keyword.operator.expression", "keyword.operator"]),
        ("operator", ["keyword.operator"]),
        ("punctuation", ["punctuation.separator", "punctuation"]),
        ("punctuation.bracket", ["meta.brace.round", "punctuation.definition.bracket", "punctuation"]),
        ("punctuation.delimiter", ["punctuation.separator.comma", "punctuation.separator", "punctuation"]),
        ("punctuation.special", ["punctuation.definition.template-expression.begin", "punctuation"]),
        ("string", ["string.quoted", "string"]),
        ("character", ["string.quoted.single", "string"]),
        ("string.escape", ["constant.character.escape"]),
        ("string.special", ["constant.character.escape", "string"]),
        ("string.regex", ["string.regexp"]),
        ("string.import", ["string.quoted", "string"]),
        ("number", ["constant.numeric"]),
        ("float", ["constant.numeric.float", "constant.numeric"]),
        ("boolean", ["constant.language.boolean", "constant.language"]),
        ("constant.builtin", ["constant.language"]),
        ("constant", ["variable.other.constant", "support.constant", "constant.other"]),
        ("constant.macro", ["entity.name.function.macro", "constant.other"]),
        ("type", ["entity.name.type", "support.type", "support.class"]),
        ("type.builtin", ["support.type", "entity.name.type"]),
        ("constructor", ["entity.name.type.class", "entity.name.type", "support.class"]),
        ("namespace", ["entity.name.namespace", "entity.name.type"]),
        ("module", ["entity.name.namespace", "entity.name.type"]),
        ("function", ["entity.name.function", "support.function"]),
        ("method", ["entity.name.function.member", "entity.name.function"]),
        ("function.macro", ["entity.name.function.macro", "entity.name.function"]),
        // A decorator is written like a call and themes colour it as one.
        ("attribute", ["entity.name.function", "entity.other.attribute"]),
        ("label", ["entity.name.label", "variable"]),
        ("variable", ["variable"]),
        ("variable.builtin", ["variable.language"]),
        ("parameter", ["variable.parameter"]),
        ("variable.parameter", ["variable.parameter"]),
        ("variable.member", ["variable.other.property", "variable.other.member", "variable"]),
        ("function.method", ["entity.name.function.member", "entity.name.function"]),
        ("function.call", ["entity.name.function"]),
        ("property", ["variable.other.property", "meta.object-literal.key", "variable.other.member", "variable"]),
        ("field", ["variable.other.property", "variable.other.member", "variable"]),
        ("tag", ["entity.name.tag"]),
        ("tag.attribute", ["entity.other.attribute-name"]),
        ("tag.delimiter", ["punctuation.definition.tag"]),
        ("text.title", ["markup.heading"]),
        ("text.strong", ["markup.bold"]),
        ("text.emphasis", ["markup.italic"]),
        ("text.literal", ["markup.inline.raw", "string"]),
        ("text.uri", ["markup.underline.link", "markup.underline"]),
        ("error", ["invalid", "Invalid"])
    ]

    private static func palette(named name: String, from theme: Parsed) -> SyntaxPalette {
        var styles: [String: SyntaxStyle] = [:]

        for entry in scopeTable {
            guard let style = style(for: entry.scopes, in: theme) else { continue }
            styles[entry.capture] = style
        }

        let grey = NSColor(srgbRed: 0.8, green: 0.8, blue: 0.8, alpha: 1)
        let foreground = color(theme.colors["editor.foreground"])
            ?? color(theme.colors["foreground"])
            ?? grey

        return SyntaxPalette(
            name: name,
            foreground: foreground,
            background: color(theme.colors["editor.background"]),
            lineNumber: color(theme.colors["editorLineNumber.foreground"]) ?? grey,
            currentLine: color(theme.colors["editor.lineHighlightBackground"]) ?? grey,
            indentGuide: color(theme.colors["editorIndentGuide.background1"])
                ?? color(theme.colors["editorIndentGuide.background"])
                ?? grey,
            styles: styles
        )
    }

    /// The theme's own answer for the first of these scopes it has one for.
    private static func style(for scopes: [String], in theme: Parsed) -> SyntaxStyle? {
        for scope in scopes {
            guard let rule = rule(for: scope, in: theme), let hex = rule.color,
                  let color = color(hex) else { continue }
            let fontStyle = rule.fontStyle ?? ""
            return SyntaxStyle(
                color: color,
                bold: fontStyle.contains("bold"),
                italic: fontStyle.contains("italic")
            )
        }
        return nil
    }

    /// TextMate matching, as much of it as a theme needs: a rule applies to a
    /// scope it names outright or is a prefix of, the most specific rule wins,
    /// and a later rule beats an earlier one of the same length — which is how
    /// a theme overrides its own base.
    private static func rule(for scope: String, in theme: Parsed) -> Rule? {
        var best: (rule: Rule, length: Int)?
        for rule in theme.rules {
            for candidate in rule.scopes {
                // Descendant selectors ("meta.tag string") need a parse tree we
                // do not have, so they are left to the more general rules.
                guard !candidate.contains(" ") else { continue }
                guard candidate == scope || scope.hasPrefix(candidate + ".") else { continue }
                if best == nil || candidate.count >= best!.length {
                    best = (rule, candidate.count)
                }
            }
        }
        return best?.rule
    }

    // MARK: - Reading the files

    /// `#RGB`, `#RRGGBB` and `#RRGGBBAA`, which is what theme files use.
    private static func color(_ hex: String?) -> NSColor? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), text.hasPrefix("#") else {
            return nil
        }
        text.removeFirst()
        if text.count == 3 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else {
            return nil
        }
        let hasAlpha = text.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// VS Code's files are JSON with comments and trailing commas, which
    /// `JSONSerialization` refuses — so both are stripped first.
    private static func object(at url: URL) -> [String: Any]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let data = Data(stripComments(from: text).utf8)
        guard let json = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else { return nil }
        return json as? [String: Any]
    }

    /// Comments and trailing commas out, everything else untouched.
    ///
    /// Scanned by Unicode scalar, not by `Character`: a settings file can hold
    /// a zero-width joiner (VS Code's own `unicodeHighlight.allowedCharacters`
    /// is full of them), and Swift clusters a joiner together with the quote
    /// beside it — which loses the end of the string and turns the rest of the
    /// file into nonsense.
    private static func stripComments(from text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = String.UnicodeScalarView()
        out.reserveCapacity(scalars.count)

        var index = 0
        var inString = false
        var escaped = false
        /// A comma is only real once something other than whitespace and a
        /// closing brace follows it — otherwise it is the trailing kind.
        var pendingComma = false

        func emit(_ scalar: Unicode.Scalar) {
            if pendingComma {
                if scalar == "}" || scalar == "]" {
                    pendingComma = false
                } else if !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    out.append(",")
                    pendingComma = false
                }
            }
            out.append(scalar)
        }

        while index < scalars.count {
            let scalar = scalars[index]

            if inString {
                out.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inString = false
                }
                index += 1
                continue
            }

            let next = index + 1 < scalars.count ? scalars[index + 1] : nil

            switch scalar {
            case "\"":
                inString = true
                emit(scalar)
            case ",":
                pendingComma = true
            case "/" where next == "/":
                while index < scalars.count, scalars[index] != "\n" { index += 1 }
                continue
            case "/" where next == "*":
                index += 2
                while index + 1 < scalars.count,
                      !(scalars[index] == "*" && scalars[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, scalars.count)
                continue
            default:
                emit(scalar)
            }
            index += 1
        }

        return String(out)
    }
}


// MARK: - Output

func literal(_ color: NSColor) -> String {
    guard let color = color.usingColorSpace(.sRGB) else { return "NSColor(hex: 0x00_00_00)" }
    let red = Int(color.redComponent * 255 + 0.5)
    let green = Int(color.greenComponent * 255 + 0.5)
    let blue = Int(color.blueComponent * 255 + 0.5)
    let hex = String(format: "0x%02X_%02X_%02X", red, green, blue)
    // Alpha is not decoration here: a current-line highlight given as
    // #6e768166 is a wash over the background, and printing only its RGB turns
    // it into a solid bar.
    guard color.alphaComponent < 0.999 else { return "NSColor(hex: \(hex))" }
    return String(format: "NSColor(hex: %@, alpha: %.3f)", hex, color.alphaComponent)
}

let requested = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil
let displayName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

let found: VSCodeTheme.Loaded?
if let requested, FileManager.default.fileExists(atPath: requested) {
    found = VSCodeTheme.load(file: URL(filePath: requested), named: displayName)
} else {
    found = VSCodeTheme.load(named: requested)
}

guard let loaded = found else {
    let what = requested.map { "theme “\($0)”" } ?? "a VS Code theme setting"
    FileHandle.standardError.write(Data("Could not find \(what).\n".utf8))
    exit(1)
}

let palette = loaded.palette
print("    static let \(loaded.name.replacingOccurrences(of: " ", with: "")) = SyntaxPalette(")
print("        name: \"\(loaded.name)\",")
print("        foreground: \(literal(palette.foreground)),")
print("        background: \(palette.background.map(literal) ?? "nil"),")
print("        lineNumber: \(literal(palette.lineNumber)),")
print("        currentLine: \(literal(palette.currentLine)),")
print("        indentGuide: \(literal(palette.indentGuide)),")
print("        styles: [")
let keys = palette.styles.keys.sorted()
for (index, key) in keys.enumerated() {
    let style = palette.styles[key]!
    var extras = ""
    if style.bold { extras += ", bold: true" }
    if style.italic { extras += ", italic: true" }
    let comma = index == keys.count - 1 ? "" : ","
    print("            \"\(key)\": SyntaxStyle(color: \(literal(style.color))\(extras))\(comma)")
}
print("        ]")
print("    )")
