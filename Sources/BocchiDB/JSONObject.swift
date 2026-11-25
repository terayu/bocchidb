/// キーの記述順を保つ JSON オブジェクト。
///
/// CouchDB は文書のキーを書かれた順に保存し、Mango ではオブジェクトどうしをその順に比べる。
/// 同じ結果を返すため、BocchiDB も順序を保って保存・同期する。
/// `==` と `hashValue` はキーの順序を区別しない（JSON としての等しさ）。
public struct JSONObject: Sendable {
    /// キー（記述順）。
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}

    /// `pairs` の順にキーを並べる。同じキーが複数あれば、最初の位置に最後の値を入れる。
    public init(_ pairs: some Sequence<(String, JSONValue)>) {
        for (key, value) in pairs { self[key] = value }
    }

    /// Dictionary は順序を持たないため、キーを並べ替えて作る。
    public init(_ dictionary: [String: JSONValue]) {
        self.init(dictionary.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }.map { ($0.key, $0.value) })
    }

    public var values: [JSONValue] { keys.map { storage[$0]! } }

    /// 値の取得と設定。新しいキーは末尾に加わり、既存のキーは位置を保ったまま値だけが変わる。`nil` を入れると削除する。
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else {
                removeValue(forKey: key)
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> JSONValue? {
        guard let value = storage.removeValue(forKey: key) else { return nil }
        keys.remove(at: keys.firstIndex(of: key)!)
        return value
    }

    /// 条件を満たすキーだけを、順序を保って残す。
    public func filter(_ isIncluded: (_ key: String, _ value: JSONValue) throws -> Bool) rethrows -> JSONObject {
        var result = JSONObject()
        for (key, value) in self where try isIncluded(key, value) { result[key] = value }
        return result
    }
}

extension JSONObject: RandomAccessCollection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { keys.count }
    public subscript(position: Int) -> (key: String, value: JSONValue) {
        (key: keys[position], value: storage[keys[position]]!)
    }
}

extension JSONObject: Hashable {
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool { lhs.storage == rhs.storage }
    public func hash(into hasher: inout Hasher) { hasher.combine(storage) }
}

extension JSONObject: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self.init(elements)
    }
}

extension JSONObject: Codable {
    private struct CodingName: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// `Decoder` はキーの順序を伝えないため、Codable 経由で読むと順序は保たれない。
    /// 順序が必要なら `JSONValue(json:)` を使う。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingName.self)
        self.init()
        for key in container.allKeys { self[key.stringValue] = try container.decode(JSONValue.self, forKey: key) }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingName.self)
        for (key, value) in self { try container.encode(value, forKey: CodingName(stringValue: key)) }
    }
}
