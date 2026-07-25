import Foundation

/// The slice of the Language Server Protocol this editor speaks.
///
/// Servers are free with their return shapes (a hover body may be a string, an
/// object, or an array of either), so the decoders here are deliberately loose.
enum LSP {

    // MARK: - Positions

    struct Position: Codable, Hashable, Sendable {
        /// Zero-based line.
        var line: Int
        /// Zero-based offset within the line, counted in UTF-16 code units.
        var character: Int
    }

    struct Range: Codable, Hashable, Sendable {
        var start: Position
        var end: Position
    }

    struct Location: Hashable, Sendable {
        var uri: String
        var range: Range

        var fileURL: URL? { URL(string: uri) }
    }

    // MARK: - Diagnostics

    enum Severity: Int, Codable, Sendable, Comparable {
        case error = 1, warning = 2, information = 3, hint = 4

        static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

        var label: String {
            switch self {
            case .error: "Error"
            case .warning: "Warning"
            case .information: "Info"
            case .hint: "Hint"
            }
        }

        var symbol: String {
            switch self {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .information: "info.circle.fill"
            case .hint: "lightbulb.fill"
            }
        }
    }

    struct Diagnostic: Decodable, Hashable, Sendable, Identifiable {
        var range: Range
        var severity: Severity?
        var source: String?
        var message: String

        var id: String { "\(range.start.line):\(range.start.character):\(message)" }
        /// Zero-based line the squiggle starts on.
        var line: Int { range.start.line }
        var level: Severity { severity ?? .error }

        private enum CodingKeys: String, CodingKey {
            case range, severity, source, message
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            range = try container.decode(Range.self, forKey: .range)
            severity = try? container.decodeIfPresent(Severity.self, forKey: .severity)
            source = try? container.decodeIfPresent(String.self, forKey: .source)
            message = (try? container.decode(String.self, forKey: .message)) ?? ""
        }

        init(range: Range, severity: Severity?, source: String?, message: String) {
            self.range = range
            self.severity = severity
            self.source = source
            self.message = message
        }
    }

    // MARK: - Completion

    struct CompletionItem: Sendable, Hashable, Identifiable {
        var label: String
        var kind: Int?
        var detail: String?
        var insertText: String?
        var filterText: String?
        var sortText: String?
        /// True when `insertText` is a snippet (`${1:name}` placeholders).
        var isSnippet: Bool
        /// Range the server wants replaced, when it supplied a text edit.
        var editRange: Range?
        var newText: String?

        var id: String { "\(label)|\(detail ?? "")|\(sortText ?? "")" }

        /// What we actually type into the buffer.
        var text: String {
            let raw = newText ?? insertText ?? label
            return isSnippet ? Self.strippingSnippet(raw) : raw
        }

        var kindLabel: String {
            switch kind ?? 0 {
            case 1: "text"
            case 2, 3: "func"
            case 4: "init"
            case 5: "field"
            case 6: "var"
            case 7: "class"
            case 8: "protocol"
            case 9: "module"
            case 10: "property"
            case 11: "unit"
            case 12: "value"
            case 13: "enum"
            case 14: "keyword"
            case 15: "snippet"
            case 16: "color"
            case 17: "file"
            case 18: "ref"
            case 21: "const"
            case 22: "struct"
            case 23: "event"
            case 25: "type"
            default: ""
            }
        }

        /// Turns `foo(${1:bar})` into `foo(bar)` — good enough without a
        /// snippet engine, and never leaves placeholder syntax in the file.
        static func strippingSnippet(_ snippet: String) -> String {
            var result = ""
            var index = snippet.startIndex
            while index < snippet.endIndex {
                let character = snippet[index]
                if character == "\\", snippet.index(after: index) < snippet.endIndex {
                    index = snippet.index(after: index)
                    result.append(snippet[index])
                    index = snippet.index(after: index)
                    continue
                }
                if character == "$" {
                    var cursor = snippet.index(after: index)
                    if cursor < snippet.endIndex, snippet[cursor] == "{" {
                        // ${1:placeholder} — keep the placeholder text.
                        cursor = snippet.index(after: cursor)
                        var inner = ""
                        var depth = 1
                        while cursor < snippet.endIndex, depth > 0 {
                            let scanned = snippet[cursor]
                            if scanned == "{" { depth += 1 }
                            if scanned == "}" {
                                depth -= 1
                                if depth == 0 { break }
                            }
                            inner.append(scanned)
                            cursor = snippet.index(after: cursor)
                        }
                        if let colon = inner.firstIndex(of: ":") {
                            result += String(inner[inner.index(after: colon)...])
                        }
                        index = cursor < snippet.endIndex ? snippet.index(after: cursor) : snippet.endIndex
                        continue
                    }
                    // $0 / $1 — drop the marker.
                    while cursor < snippet.endIndex, snippet[cursor].isNumber {
                        cursor = snippet.index(after: cursor)
                    }
                    index = cursor
                    continue
                }
                result.append(character)
                index = snippet.index(after: index)
            }
            return result
        }
    }

    // MARK: - Symbols

    struct Symbol: Sendable, Hashable, Identifiable {
        var name: String
        var detail: String?
        var kind: Int
        var line: Int
        var depth: Int

        var id: String { "\(depth):\(line):\(name)" }

        var symbol: String {
            switch kind {
            case 2, 3, 4: "shippingbox"
            case 5: "c.square"
              case 6, 12: "function"
            case 7, 8: "p.square"
            case 9: "gearshape"
            case 10: "e.square"
            case 11: "square.on.square"
            case 13, 14: "v.square"
            case 23: "s.square"
            case 26: "t.square"
            default: "circle"
            }
        }
    }
}

// MARK: - Loose decoding helpers

extension LSP {
    /// Reads `Location | Location[] | LocationLink[]`, as servers all differ.
    static func decodeLocations(_ value: Any?) -> [Location] {
        func location(from dictionary: [String: Any]) -> Location? {
            guard let uri = (dictionary["uri"] ?? dictionary["targetUri"]) as? String else { return nil }
            let rangeValue = (dictionary["range"] ?? dictionary["targetSelectionRange"] ?? dictionary["targetRange"])
            guard let rangeDictionary = rangeValue as? [String: Any],
                  let range = decodeRange(rangeDictionary) else { return nil }
            return Location(uri: uri, range: range)
        }

        if let dictionary = value as? [String: Any], let single = location(from: dictionary) {
            return [single]
        }
        if let array = value as? [[String: Any]] {
            return array.compactMap(location(from:))
        }
        return []
    }

    static func decodeRange(_ dictionary: [String: Any]) -> Range? {
        guard let start = dictionary["start"] as? [String: Any],
              let end = dictionary["end"] as? [String: Any],
              let startLine = start["line"] as? Int,
              let startCharacter = start["character"] as? Int,
              let endLine = end["line"] as? Int,
              let endCharacter = end["character"] as? Int else { return nil }
        return Range(
            start: Position(line: startLine, character: startCharacter),
            end: Position(line: endLine, character: endCharacter)
        )
    }

    /// Flattens `MarkupContent | MarkedString | (MarkupContent | MarkedString)[]`
    /// into plain text for the hover panel.
    static func decodeHoverText(_ value: Any?) -> String? {
        func text(from any: Any) -> String? {
            if let string = any as? String { return string }
            if let dictionary = any as? [String: Any] {
                if let value = dictionary["value"] as? String { return value }
            }
            return nil
        }

        guard let result = value as? [String: Any] else { return nil }
        let contents = result["contents"]

        var pieces: [String] = []
        if let array = contents as? [Any] {
            pieces = array.compactMap(text(from:))
        } else if let contents, let single = text(from: contents) {
            pieces = [single]
        }

        let joined = pieces
            .map { stripMarkdownFences($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// Hover bodies usually arrive as fenced code blocks; the fences add noise
    /// in a plain-text panel.
    private static func stripMarkdownFences(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads `CompletionList | CompletionItem[]`.
    static func decodeCompletions(_ value: Any?) -> [CompletionItem] {
        let rawItems: [[String: Any]]
        if let list = value as? [String: Any], let items = list["items"] as? [[String: Any]] {
            rawItems = items
        } else if let items = value as? [[String: Any]] {
            rawItems = items
        } else {
            return []
        }

        return rawItems.compactMap { item in
            guard let label = item["label"] as? String else { return nil }
            let format = item["insertTextFormat"] as? Int
            var editRange: Range?
            var newText: String?
            if let edit = item["textEdit"] as? [String: Any] {
                newText = edit["newText"] as? String
                if let rangeDictionary = (edit["range"] ?? edit["replace"]) as? [String: Any] {
                    editRange = decodeRange(rangeDictionary)
                }
            }
            return CompletionItem(
                label: label,
                kind: item["kind"] as? Int,
                detail: item["detail"] as? String,
                insertText: item["insertText"] as? String,
                filterText: item["filterText"] as? String,
                sortText: item["sortText"] as? String,
                isSnippet: format == 2,
                editRange: editRange,
                newText: newText
            )
        }
    }

    /// Reads `DocumentSymbol[] | SymbolInformation[]`, flattened with depth.
    static func decodeSymbols(_ value: Any?) -> [Symbol] {
        guard let array = value as? [[String: Any]] else { return [] }
        var result: [Symbol] = []

        func walk(_ items: [[String: Any]], depth: Int) {
            for item in items {
                guard let name = item["name"] as? String else { continue }
                let kind = item["kind"] as? Int ?? 0
                let line: Int
                if let selection = item["selectionRange"] as? [String: Any],
                   let range = decodeRange(selection) {
                    line = range.start.line
                } else if let rangeDictionary = item["range"] as? [String: Any],
                          let range = decodeRange(rangeDictionary) {
                    line = range.start.line
                } else if let location = item["location"] as? [String: Any],
                          let rangeDictionary = location["range"] as? [String: Any],
                          let range = decodeRange(rangeDictionary) {
                    line = range.start.line
                } else {
                    continue
                }
                result.append(
                    Symbol(
                        name: name,
                        detail: item["detail"] as? String,
                        kind: kind,
                        line: line,
                        depth: depth
                    )
                )
                if let children = item["children"] as? [[String: Any]] {
                    walk(children, depth: depth + 1)
                }
            }
        }

        walk(array, depth: 0)
        return result
    }
}
