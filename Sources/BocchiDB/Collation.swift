import Foundation

/// CouchDB と同じ順序で JSON 値を比較する（Mango クエリの比較と並べ替えに使う）。
///
/// 型の順序は null < false < true < 数値 < 文字列 < 配列 < オブジェクト。
/// 文字列は ICU の照合順序（"a" < "A" < "b"、"あ" < "ア" < "い"）で比べ、Unicode として等価な文字列は等しい。
enum Collation {
    static func compare(_ a: JSONValue, _ b: JSONValue) -> ComparisonResult {
        let (rankA, rankB) = (rank(a), rank(b))
        if rankA != rankB { return rankA < rankB ? .orderedAscending : .orderedDescending }
        switch (a, b) {
        case (.int(let x), .int(let y)):
            return order(x, y)
        case (.int, _), (.double, _):
            return order(a.doubleValue, b.doubleValue)
        case (.string(let x), .string(let y)):
            return compareStrings(x, y)
        case (.array(let x), .array(let y)):
            for (u, v) in zip(x, y) {
                let result = compare(u, v)
                if result != .orderedSame { return result }
            }
            return order(x.count, y.count)
        case (.object(let x), .object(let y)):
            // CouchDB はキーの記述順に比べるが、JSONValue は順序を持たないため、キーを並べ替えて比べる。
            let (keysX, keysY) = (x.keys.sorted(by: stringLess), y.keys.sorted(by: stringLess))
            for (kx, ky) in zip(keysX, keysY) {
                let keyResult = compareStrings(kx, ky)
                if keyResult != .orderedSame { return keyResult }
                let valueResult = compare(x[kx]!, y[ky]!)
                if valueResult != .orderedSame { return valueResult }
            }
            return order(keysX.count, keysY.count)
        default:
            return .orderedSame  // null 同士、または同じ値の Bool
        }
    }

    /// `_id` の比較。CouchDB は `_id` を照合順序ではなくバイト列（UTF-8）で比べる。
    static func compareRaw(_ a: JSONValue, _ b: JSONValue) -> ComparisonResult {
        guard case .string(let x) = a, case .string(let y) = b else { return compare(a, b) }
        return x.utf8.lexicographicallyPrecedes(y.utf8) ? .orderedAscending
            : y.utf8.lexicographicallyPrecedes(x.utf8) ? .orderedDescending : .orderedSame
    }

    private static let root = Locale(identifier: "")

    /// NFC に正規化してから比べる。正規化しないと、OS の比較ではカタカナがひらがなより前になり CouchDB と食い違う。
    private static func compareStrings(_ a: String, _ b: String) -> ComparisonResult {
        a.precomposedStringWithCanonicalMapping.compare(
            b.precomposedStringWithCanonicalMapping, options: .literal, range: nil, locale: root)
    }

    private static func stringLess(_ a: String, _ b: String) -> Bool {
        compareStrings(a, b) == .orderedAscending
    }

    private static func rank(_ value: JSONValue) -> Int {
        switch value {
        case .null: 0
        case .bool(false): 1
        case .bool(true): 2
        case .int, .double: 3
        case .string: 4
        case .array: 5
        case .object: 6
        }
    }

    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }
}

private extension JSONValue {
    var doubleValue: Double {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: 0
        }
    }
}
