import Foundation

/// A JSON value whose shape is not known ahead of time.
///
/// A line of a `claude` transcript is one of these: what a tool was passed and
/// what came back depend on which tool ran, so they cannot be decoded into a
/// struct. They arrive here instead and are reached into by key — see
/// ``ClaudeSessionsIndex``, which reads a conversation's title out of the head
/// of its file. `Sendable` matters: the parse happens off the main actor.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognised JSON value"
            )
        }
    }

    /// Decodes one line of JSONL. Returns nil for a line that is not JSON at
    /// all — a tool that writes a stray line to stdout should not kill the
    /// stream.
    static func parse(_ line: String) -> JSONValue? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        doubleValue.map(Int.init)
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let values) = self else { return nil }
        return values
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let fields) = self else { return nil }
        return fields
    }

    /// The value as something readable in the UI. A string is itself — quoting
    /// it would only get in the way of a shell command or a file path — and
    /// anything nested falls back to pretty-printed JSON.
    var displayText: String {
        switch self {
        case .null: "null"
        case .bool(let value): value ? "true" : "false"
        case .number(let value):
            value == value.rounded() && abs(value) < 1e15
                ? String(Int(value))
                : String(value)
        case .string(let value): value
        case .array(let values): values.map(\.displayText).joined(separator: "\n")
        case .object: prettyPrinted
        }
    }

    private var prettyPrinted: String {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              ),
              let text = String(data: pretty, encoding: .utf8)
        else { return "" }
        return text
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let fields): try container.encode(fields)
        }
    }
}
