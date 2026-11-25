/// 任意の JSON 値。
///
/// 数値は整数（`Int64` の範囲）と小数を区別して保持するが、比較は数値として行う。
/// JSON では `26` と `26.0` は同じ数なので、`.int(26) == .double(26.0)` は true になる。
/// オブジェクトはキーの記述順を保つ（`JSONObject`）。順序を保って読み書きするには `init(json:)` と `jsonData()` を使う。
public enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

/// Codable 経由ではオブジェクトのキーの順序は保たれない（`JSONObject` を参照）。
extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Bool → 整数 → 小数 の順に試す（keepsBoolAndNumberDistinct / keepsIntegerAndFractionDistinct で検証）。
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(JSONObject(elements))
    }
}


extension JSONValue: Hashable {
    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case (.bool(let a), .bool(let b)): a == b
        case (.int(let a), .int(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.int(let a), .double(let b)), (.double(let b), .int(let a)): Double(exactly: a) == b
        case (.string(let a), .string(let b)): a == b
        case (.array(let a), .array(let b)): a == b
        case (.object(let a), .object(let b)): a == b
        default: false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .null:
            hasher.combine(0)
        case .bool(let value):
            hasher.combine(value)
        case .int(let value):
            hasher.combine(value)
        case .double(let value):
            // 整数と等しい小数は、その整数と同じハッシュにする。
            if let integer = Int64(exactly: value) { hasher.combine(integer) } else { hasher.combine(value) }
        case .string(let value):
            hasher.combine(value)
        case .array(let value):
            hasher.combine(value)
        case .object(let value):
            hasher.combine(value)
        }
    }
}
