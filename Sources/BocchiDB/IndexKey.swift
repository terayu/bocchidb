import Foundation

/// 索引のキー。ICU（文字列の照合順序）に依存しない形で保存し、検索の候補を絞るためだけに使う。
///
/// 照合順序が必要な判定（文字列の大小など）は検索時に評価器で行うため、OS の更新で ICU の並び順が変わっても
/// 索引が誤った状態になることはない。キーの範囲は常に「一致しうる文書をすべて含む」ように作る。
///
/// 値の形式（型ごとの先頭バイトの順序は、照合順序の型の順序と同じ）:
/// - null `10`、false `20`、true `30`
/// - 数値 `40` + 大小関係を保つ 8 バイト
/// - その他の文字列 `50`（内容は保存しない）
/// - 単純な文字列 `51` + UTF-8 + `00`
/// - 配列 `60`、オブジェクト `70`（内容は保存しない）
enum IndexKey {
    typealias Bytes = [UInt8]

    static let nullTag: UInt8 = 0x10
    static let falseTag: UInt8 = 0x20
    static let trueTag: UInt8 = 0x30
    static let numberTag: UInt8 = 0x40
    static let otherStringTag: UInt8 = 0x50
    static let simpleStringTag: UInt8 = 0x51
    static let arrayTag: UInt8 = 0x60
    static let objectTag: UInt8 = 0x70

    static func encode(_ value: JSONValue) -> Bytes {
        switch value {
        case .null: [nullTag]
        case .bool(let flag): [flag ? trueTag : falseTag]
        case .int(let number): [numberTag] + encodeNumber(Double(number))
        case .double(let number): [numberTag] + encodeNumber(number)
        case .string(let string): isSimple(string) ? [simpleStringTag] + Array(string.utf8) + [0] : [otherStringTag]
        case .array: [arrayTag]
        case .object: [objectTag]
        }
    }

    /// バイト列で比べても大小関係が保たれる形（IEEE 754 の符号を反転）。
    /// `Int64` の大きな値は `Double` に丸められて同じキーになることがあるが、候補が増えるだけで取りこぼしはない。
    static func encodeNumber(_ number: Double) -> Bytes {
        let bits = (number == 0 ? 0 : number).bitPattern  // -0.0 を 0.0 にそろえる
        let ordered = bits & (1 << 63) != 0 ? ~bits : bits | (1 << 63)
        return (0..<8).map { UInt8(truncatingIfNeeded: ordered >> (56 - 8 * $0)) }
    }

    /// 照合順序で等しいならバイト列も等しい、と言える文字だけでできた文字列。
    ///
    /// ICU は制御文字やゼロ幅スペースなどを無視して比べる（"ab" と "a\u{200B}b" は等しい）ため、
    /// そうした文字を含みうる文字列は「その他の文字列」として内容を保存せず、文字列の検索では常に候補に含める。
    /// 対象の文字はすべて NFC で変化しないので、UTF-8 のバイト列はそのまま正規化済みの形になる。
    static func isSimple(_ string: String) -> Bool {
        string.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x20...0x7E: true                               // ASCII の表示可能文字
            case 0xC0...0xFF: scalar.value != 0xD7 && scalar.value != 0xF7  // Latin-1 の文字（× ÷ を除く）
            case 0x3041...0x3096: true                           // ひらがな
            case 0x30A1...0x30FA, 0x30FC: true                   // カタカナと長音記号
            case 0x3400...0x4DBF, 0x4E00...0x9FFF: true          // CJK 統合漢字
            default: false
            }
        }
    }

    /// `prefix` で始まるすべてのバイト列より大きい、最小のバイト列。上限がない場合は `nil`。
    static func successor(_ prefix: Bytes) -> Bytes? {
        var bytes = prefix
        while let last = bytes.last {
            if last < 0xFF {
                bytes[bytes.count - 1] = last + 1
                return bytes
            }
            bytes.removeLast()
        }
        return nil
    }
}

/// キーの範囲 [lower, upper)。`upper` が `nil` なら上限なし。
struct KeyInterval: Equatable {
    var lower: IndexKey.Bytes
    var upper: IndexKey.Bytes?

    /// `prefix` で始まるすべてのキー。
    static func all(_ prefix: IndexKey.Bytes) -> KeyInterval {
        KeyInterval(lower: prefix, upper: IndexKey.successor(prefix))
    }

    var isEmpty: Bool {
        guard let upper else { return false }
        return !lower.lexicographicallyPrecedes(upper)
    }

    func intersection(_ other: KeyInterval) -> KeyInterval {
        let lower = lower.lexicographicallyPrecedes(other.lower) ? other.lower : lower
        let upper: IndexKey.Bytes? = switch (upper, other.upper) {
        case (nil, let bound), (let bound, nil): bound
        case (let a?, let b?): a.lexicographicallyPrecedes(b) ? a : b
        }
        return KeyInterval(lower: lower, upper: upper)
    }

    /// 重なる範囲や隣り合う範囲をまとめ、下限の順に並べる。
    static func merged(_ intervals: [KeyInterval]) -> [KeyInterval] {
        var result: [KeyInterval] = []
        for interval in intervals.filter({ !$0.isEmpty }).sorted(by: { $0.lower.lexicographicallyPrecedes($1.lower) }) {
            if let last = result.last, last.upper.map({ !$0.lexicographicallyPrecedes(interval.lower) }) ?? true {
                let upper: IndexKey.Bytes? = switch (last.upper, interval.upper) {
                case (nil, _), (_, nil): nil
                case (let a?, let b?): a.lexicographicallyPrecedes(b) ? b : a
                }
                result[result.count - 1].upper = upper
            } else {
                result.append(interval)
            }
        }
        return result
    }
}

/// セレクタから、索引で読むキーの範囲を決める。
enum IndexPlanner {
    /// 1 回の検索で扱う、先頭のフィールドの組み合わせの上限。
    private static let maxPrefixes = 32

    /// `fields` の索引で読むべきキーの範囲。索引が使えない場合は `nil`。
    ///
    /// 索引には全フィールドを持つ文書しか入らないため、すべてのフィールドについて、
    /// フィールドがない文書には一致しない条件がトップレベルにある場合だけ使う（CouchDB と同じ条件）。
    static func intervals(for selector: Selector, fields: [[String]]) -> [KeyInterval]? {
        let conditions = topLevelConditions(selector)
        guard fields.allSatisfy({ field in conditions.contains { $0.path == field && $0.requiresField } }) else {
            return nil
        }

        var prefixes: [IndexKey.Bytes] = [[]]
        for (position, field) in fields.enumerated() {
            let positive = conditions.filter { $0.path == field && !$0.negated }.map(\.op)
            // 最後のフィールドより前は、等価の条件があれば先頭のキーを延ばして次のフィールドへ進む。
            if position < fields.count - 1, let keys = positive.lazy.compactMap(exactKeys).first,
               prefixes.count * keys.count <= maxPrefixes {
                prefixes = prefixes.flatMap { prefix in keys.map { prefix + $0 } }
                continue
            }
            return KeyInterval.merged(prefixes.flatMap { prefix in
                positive.reduce([KeyInterval.all(prefix)]) { current, op in
                    guard let restriction = intervals(for: op, prefix: prefix) else { return current }
                    return current.flatMap { a in restriction.map { a.intersection($0) } }
                }
            })
        }
        return KeyInterval.merged(prefixes.map(KeyInterval.all))
    }

    private struct Condition {
        let path: [String]
        let op: Selector.Operator
        let negated: Bool

        /// フィールドがない文書には一致しない条件か。
        var requiresField: Bool {
            if case .exists(let expected) = op { return expected != negated }
            return true
        }
    }

    private static func topLevelConditions(_ selector: Selector) -> [Condition] {
        switch selector {
        case .and(let parts): parts.flatMap(topLevelConditions)
        case .or: []
        case .condition(let path, let op, let negated): [Condition(path: path, op: op, negated: negated)]
        }
    }

    /// 等価の条件で、値が取りうるキーの先頭部分（次のフィールドのキーがこの後に続く）。
    private static func exactKeys(_ op: Selector.Operator) -> [IndexKey.Bytes]? {
        guard case .eq(let value) = op else { return nil }
        if case .string(let string) = value {
            guard IndexKey.isSimple(string) else { return nil }
            return [IndexKey.encode(value), [IndexKey.otherStringTag]]
        }
        return [IndexKey.encode(value)]
    }

    /// 1 つの条件で、値が取りうるキーの範囲。絞り込めない条件は `nil`。
    private static func intervals(for op: Selector.Operator, prefix: IndexKey.Bytes) -> [KeyInterval]? {
        func exact(_ key: IndexKey.Bytes) -> KeyInterval { .all(prefix + key) }
        func tags(_ first: UInt8, _ last: UInt8) -> KeyInterval {
            KeyInterval(lower: prefix + [first], upper: prefix + [last + 1])
        }
        /// 値と等しくなりうるキー。
        func equal(_ value: JSONValue) -> [KeyInterval] {
            switch value {
            case .string(let string) where IndexKey.isSimple(string):
                [exact(IndexKey.encode(value)), exact([IndexKey.otherStringTag])]
            case .string: [tags(IndexKey.otherStringTag, IndexKey.simpleStringTag)]
            default: [exact(IndexKey.encode(value))]
            }
        }
        /// 値以上になりうるキーの下限。文字列・配列・オブジェクトは型の先頭から。
        func lowerBound(_ value: JSONValue) -> IndexKey.Bytes {
            switch value {
            case .string: prefix + [IndexKey.otherStringTag]
            default: prefix + IndexKey.encode(value)
            }
        }
        /// 値以下になりうるキーの上限（この値を含まない）。文字列・配列・オブジェクトは型の終わりまで。
        func upperBound(_ value: JSONValue) -> IndexKey.Bytes? {
            switch value {
            case .string: prefix + [IndexKey.simpleStringTag + 1]
            case .array: prefix + [IndexKey.arrayTag + 1]
            case .object: prefix + [IndexKey.objectTag + 1]
            default: IndexKey.successor(prefix + IndexKey.encode(value))
            }
        }

        switch op {
        case .eq(let value):
            return equal(value)
        case .gt(let value), .gte(let value):
            return [KeyInterval(lower: lowerBound(value), upper: IndexKey.successor(prefix))]
        case .lt(let value), .lte(let value):
            return [KeyInterval(lower: prefix, upper: upperBound(value))]
        case .in(let values):
            // 配列のフィールドは要素で照合するため、配列の文書も候補に含める。
            return values.flatMap(equal) + [tags(IndexKey.arrayTag, IndexKey.arrayTag)]
        case .beginsWith(let start):
            guard IndexKey.isSimple(start) else { return [tags(IndexKey.otherStringTag, IndexKey.simpleStringTag)] }
            return [exact([IndexKey.simpleStringTag] + Array(start.utf8)), exact([IndexKey.otherStringTag])]
        case .type(let type):
            return switch type {
            case "null": [tags(IndexKey.nullTag, IndexKey.nullTag)]
            case "boolean": [tags(IndexKey.falseTag, IndexKey.trueTag)]
            case "number": [tags(IndexKey.numberTag, IndexKey.numberTag)]
            case "string": [tags(IndexKey.otherStringTag, IndexKey.simpleStringTag)]
            case "array": [tags(IndexKey.arrayTag, IndexKey.arrayTag)]
            default: [tags(IndexKey.objectTag, IndexKey.objectTag)]
            }
        default:
            return nil
        }
    }
}
