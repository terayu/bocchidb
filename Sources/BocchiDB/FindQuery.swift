import Foundation

/// Mango クエリ（CouchDB の `_find` と同じ形式）。
///
/// ```swift
/// let docs = try await db.find(FindQuery(
///     selector: ["type": "inspection", "temperature": ["$gte": 25]],
///     sort: [SortField("temperature", .descending)], limit: 10))
/// ```
public struct FindQuery: Sendable, Equatable {
    /// 条件。CouchDB の `selector` と同じ JSON オブジェクト。
    public var selector: JSONValue
    /// 並べ替え。すべて同じ向きにする（CouchDB と同じ制約）。並べ替えるフィールドがない文書は結果に含まれない。
    /// 空のときは `_id` 順。
    public var sort: [SortField]
    /// 返す件数の上限。`nil` なら全件（CouchDB の既定は 25 件）。
    public var limit: Int?
    /// 先頭から読み飛ばす件数。
    public var skip: Int
    /// 本文に含めるフィールド（`"a.b"` のように入れ子も指定できる）。`nil` なら本文全体。
    ///
    /// `Document.id` と `rev` は常に入る。添付の情報は `"_attachments"` を含めたときだけ読み込む。
    public var fields: [String]?

    public init(
        selector: JSONValue, sort: [SortField] = [], limit: Int? = nil, skip: Int = 0, fields: [String]? = nil
    ) {
        self.selector = selector
        self.sort = sort
        self.limit = limit
        self.skip = skip
        self.fields = fields
    }

    /// CouchDB の `_find` に送る JSON（`selector`、`sort`、`limit`、`skip`、`fields`）から作る。
    public init(json: Data) throws {
        guard case .object(let object)? = try? JSONValue(json: json) else {
            throw BocchiDBError.invalidQuery("query must be a JSON object")
        }
        for key in object.keys where !["selector", "sort", "limit", "skip", "fields"].contains(key) {
            throw BocchiDBError.invalidQuery("unsupported key: \(key)")
        }
        guard let selector = object["selector"] else { throw BocchiDBError.invalidQuery("selector is required") }
        self.init(selector: selector)

        if let sort = object["sort"] {
            guard case .array(let items) = sort else { throw BocchiDBError.invalidQuery("sort must be an array") }
            self.sort = try items.map { item in
                switch item {
                case .string(let field):
                    return SortField(field)
                case .object(let entry) where entry.count == 1:
                    let (field, direction) = entry.first!
                    switch direction {
                    case "asc": return SortField(field, .ascending)
                    case "desc": return SortField(field, .descending)
                    default: throw BocchiDBError.invalidQuery("sort direction must be \"asc\" or \"desc\"")
                    }
                default:
                    throw BocchiDBError.invalidQuery("invalid sort field")
                }
            }
        }
        if let limit = object["limit"] {
            guard case .int(let value) = limit else { throw BocchiDBError.invalidQuery("limit must be an integer") }
            self.limit = Int(value)
        }
        if let skip = object["skip"] {
            guard case .int(let value) = skip else { throw BocchiDBError.invalidQuery("skip must be an integer") }
            self.skip = Int(value)
        }
        if let fields = object["fields"] {
            guard case .array(let items) = fields else { throw BocchiDBError.invalidQuery("fields must be an array") }
            self.fields = try items.map {
                guard case .string(let field) = $0 else { throw BocchiDBError.invalidQuery("fields must be strings") }
                return field
            }
        }
    }
}

/// 並べ替えるフィールドと向き。
public struct SortField: Sendable, Equatable {
    public var field: String
    public var direction: SortDirection

    public init(_ field: String, _ direction: SortDirection = .ascending) {
        self.field = field
        self.direction = direction
    }
}

public enum SortDirection: Sendable, Equatable {
    case ascending
    case descending
}

// MARK: - 実行計画（内部）

/// `FindQuery` を検証し、照合・並べ替え・絞り込みを行う。
struct FindPlan {
    /// 照合の対象になる文書。
    struct Candidate {
        let id: String
        let rev: RevisionID
        let body: JSONObject
        let docPK: Int64
        /// 照合に使う値（本文に `_id` と `_rev` を加えたもの）。
        let value: JSONValue
    }

    let selector: Selector
    private let sortPaths: [[String]]
    private let descending: Bool
    private let skip: Int
    private let limit: Int?
    private let fieldPaths: [[String]]?
    /// 添付の情報を読み込むか。
    let includesAttachments: Bool

    init(_ query: FindQuery) throws {
        selector = try Selector.parse(query.selector)
        sortPaths = try query.sort.map { try Self.parsePath($0.field) }
        let directions = Set(query.sort.map(\.direction))
        guard directions.count <= 1 else {
            throw BocchiDBError.invalidQuery("all sort fields must have the same direction")
        }
        descending = directions.first == .descending
        guard query.skip >= 0, (query.limit ?? 0) >= 0 else {
            throw BocchiDBError.invalidQuery("limit and skip must not be negative")
        }
        skip = query.skip
        limit = query.limit
        fieldPaths = try query.fields?.filter { !["_id", "_rev", "_attachments"].contains($0) }.map(Self.parsePath)
        includesAttachments = query.fields.map { $0.contains("_attachments") } ?? true
    }

    static func candidate(id: String, rev: RevisionID, body: JSONObject, docPK: Int64) -> Candidate {
        var value = body
        value["_id"] = .string(id)
        value["_rev"] = .string(rev.description)
        return Candidate(id: id, rev: rev, body: body, docPK: docPK, value: .object(value))
    }

    func matches(_ candidate: Candidate) -> Bool {
        selector.matches(candidate.value)
    }

    /// `_id` 順に並んだ候補を並べ替え、`skip` と `limit` を適用する。
    func arrange(_ candidates: [Candidate]) -> [Candidate] {
        var result = candidates
        if !sortPaths.isEmpty {
            // CouchDB は並べ替えに索引を使うため、並べ替えるフィールドがない文書は結果に含まれない。
            let keyed = candidates.compactMap { candidate -> (keys: [JSONValue], candidate: Candidate)? in
                var keys: [JSONValue] = []
                for path in sortPaths {
                    guard case .found(let value) = Selector.resolve(candidate.value, path) else { return nil }
                    keys.append(value)
                }
                return (keys, candidate)
            }
            result = keyed.sorted { a, b in
                for (path, (x, y)) in zip(sortPaths, zip(a.keys, b.keys)) {
                    let order = path == ["_id"] ? Collation.compareRaw(x, y) : Collation.compare(x, y)
                    if order != .orderedSame { return order == .orderedAscending }
                }
                return Collation.compareRaw(.string(a.candidate.id), .string(b.candidate.id)) == .orderedAscending
            }.map(\.candidate)
            if descending { result.reverse() }
        }
        let skipped = result.dropFirst(skip)
        return Array(limit.map { skipped.prefix($0) } ?? skipped)
    }

    /// `fields` で指定したフィールドだけを残した本文。
    func project(_ body: JSONObject) -> JSONObject {
        guard let fieldPaths else { return body }
        var result: JSONObject = [:]
        for path in fieldPaths { Self.copy(path[...], from: body, into: &result) }
        return result
    }

    private static func copy(_ path: ArraySlice<String>, from source: JSONObject, into target: inout JSONObject) {
        guard let key = path.first, let value = source[key] else { return }
        if path.count == 1 {
            target[key] = value
            return
        }
        guard case .object(let child) = value else { return }
        var nested: JSONObject = if case .object(let existing)? = target[key] { existing } else { [:] }
        copy(path.dropFirst(), from: child, into: &nested)
        if !nested.isEmpty { target[key] = .object(nested) }
    }

    /// `"a.b"` をフィールド名の列にする。`\.` はフィールド名に含まれるドット。
    static func parsePath(_ field: String) throws -> [String] {
        guard !field.isEmpty else { throw BocchiDBError.invalidQuery("field name must not be empty") }
        var components: [String] = []
        var current = ""
        var escaping = false
        for character in field {
            if escaping {
                current.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else if character == "." {
                components.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        components.append(current)
        return components
    }
}

// MARK: - セレクタ

/// 正規化したセレクタ。`$not` と `$nor` は、ド・モルガンの法則で個々の条件の否定まで押し下げてある。
indirect enum Selector {
    case and([Selector])
    case or([Selector])
    /// `path` の値に対する条件。`negated` なら結果を反転する（ただしフィールドがない場合は反転しない）。
    case condition(path: [String], op: Operator, negated: Bool)

    enum Operator {
        case eq(JSONValue), ne(JSONValue), gt(JSONValue), gte(JSONValue), lt(JSONValue), lte(JSONValue)
        case `in`([JSONValue]), nin([JSONValue]), all([JSONValue])
        case exists(Bool), type(String), size(Int)
        case mod(divisor: Int64, remainder: Int64)
        case regex(NSRegularExpression)
        case beginsWith(String)
        case elemMatch(Selector), allMatch(Selector)
    }

    enum Resolved {
        case found(JSONValue)
        case missing
        /// 途中のフィールドがオブジェクトでも配列でもない。
        case badPath
    }

    static func parse(_ selector: JSONValue) throws -> Selector {
        guard case .object(let object) = selector else { throw BocchiDBError.invalidQuery("selector must be a JSON object") }
        return try parseObject(object, path: [], negated: false)
    }

    func matches(_ root: JSONValue) -> Bool {
        switch self {
        case .and(let parts):
            return parts.allSatisfy { $0.matches(root) }
        case .or(let parts):
            return parts.contains { $0.matches(root) }
        case .condition(let path, let op, let negated):
            switch Self.resolve(root, path) {
            case .badPath:
                return false
            case .missing:
                // CouchDB と同じく、フィールドがない文書は否定しても条件を満たさない。
                // 例外は $exists で、{"$not": {"f": {"$exists": true}}} はフィールドがない文書に一致する。
                if case .exists(let expected) = op { return expected == negated }
                return false
            case .found(let value):
                let compare = path == ["_id"] ? Collation.compareRaw : Collation.compare
                return op.matches(value, compare) != negated
            }
        }
    }

    static func resolve(_ root: JSONValue, _ path: [String]) -> Resolved {
        var current = root
        for key in path {
            switch current {
            case .object(let object):
                guard let next = object[key] else { return .missing }
                current = next
            case .array(let array):
                guard let index = Int(key), index >= 0 else { return .badPath }
                guard index < array.count else { return .missing }
                current = array[index]
            default:
                return .badPath
            }
        }
        return .found(current)
    }

    // MARK: 解析

    /// 同じ階層の条件は AND。否定されているときは、ド・モルガンの法則で OR になる。
    private static func junction(_ parts: [Selector], negated: Bool) -> Selector {
        if parts.count == 1 { return parts[0] }
        return negated ? .or(parts) : .and(parts)
    }

    private static func parseObject(_ object: JSONObject, path: [String], negated: Bool) throws -> Selector {
        let parts = try object.sorted { $0.key < $1.key }.map { key, value in
            try parseEntry(key, value, path: path, negated: negated)
        }
        return junction(parts, negated: negated)
    }

    private static func parseEntry(_ key: String, _ value: JSONValue, path: [String], negated: Bool) throws -> Selector {
        switch key {
        case "$and":
            return junction(try parseArray(key, value, path: path, negated: negated), negated: negated)
        case "$or":
            return junction(try parseArray(key, value, path: path, negated: negated), negated: !negated)
        case "$nor":
            // $nor = すべて満たさない = 各条件の否定の AND。
            return junction(try parseArray(key, value, path: path, negated: !negated), negated: negated)
        case "$not":
            guard case .object(let object) = value else { throw BocchiDBError.invalidQuery("$not requires an object") }
            return try parseObject(object, path: path, negated: !negated)
        case let op where op.hasPrefix("$"):
            return .condition(path: path, op: try parseOperator(op, value), negated: negated)
        default:
            return try parseValue(value, path: path + FindPlan.parsePath(key), negated: negated)
        }
    }

    private static func parseArray(_ key: String, _ value: JSONValue, path: [String], negated: Bool) throws -> [Selector] {
        guard case .array(let items) = value else { throw BocchiDBError.invalidQuery("\(key) requires an array") }
        return try items.map { item in
            guard case .object(let object) = item else { throw BocchiDBError.invalidQuery("\(key) requires objects") }
            return try parseObject(object, path: path, negated: negated)
        }
    }

    /// フィールドの値。演算子を含まないオブジェクトは入れ子のフィールド、それ以外は `$eq`。
    private static func parseValue(_ value: JSONValue, path: [String], negated: Bool) throws -> Selector {
        if case .object(let object) = value, !object.isEmpty {
            return try parseObject(object, path: path, negated: negated)
        }
        return .condition(path: path, op: .eq(value), negated: negated)
    }

    private static let types: Set<String> = ["null", "boolean", "number", "string", "array", "object"]

    private static func parseOperator(_ op: String, _ arg: JSONValue) throws -> Operator {
        func invalid(_ message: String) -> BocchiDBError { .invalidQuery("\(op) \(message)") }
        switch (op, arg) {
        case ("$eq", _): return .eq(arg)
        case ("$ne", _): return .ne(arg)
        case ("$gt", _): return .gt(arg)
        case ("$gte", _): return .gte(arg)
        case ("$lt", _): return .lt(arg)
        case ("$lte", _): return .lte(arg)
        case ("$in", .array(let items)): return .in(items)
        case ("$nin", .array(let items)): return .nin(items)
        case ("$all", .array(let items)): return .all(items)
        case ("$exists", .bool(let flag)): return .exists(flag)
        case ("$type", .string(let type)) where types.contains(type): return .type(type)
        case ("$size", .int(let size)): return .size(Int(size))
        case ("$mod", .array(let items)):
            guard items.count == 2, case .int(let divisor) = items[0], case .int(let remainder) = items[1], divisor != 0
            else { throw invalid("requires [divisor, remainder] with a non-zero integer divisor") }
            return .mod(divisor: divisor, remainder: remainder)
        case ("$regex", .string(let pattern)):
            do { return .regex(try NSRegularExpression(pattern: pattern)) } catch { throw invalid("has an invalid pattern") }
        case ("$beginsWith", .string(let prefix)): return .beginsWith(prefix)
        case ("$elemMatch", .object(let object)): return .elemMatch(try parseObject(object, path: [], negated: false))
        case ("$allMatch", .object(let object)): return .allMatch(try parseObject(object, path: [], negated: false))
        case ("$in", _), ("$nin", _), ("$all", _): throw invalid("requires an array")
        case ("$exists", _): throw invalid("requires a boolean")
        case ("$type", _): throw invalid("requires one of \(types.sorted().joined(separator: ", "))")
        case ("$size", _): throw invalid("requires an integer")
        case ("$mod", _): throw invalid("requires an array")
        case ("$regex", _), ("$beginsWith", _): throw invalid("requires a string")
        case ("$elemMatch", _), ("$allMatch", _): throw invalid("requires an object")
        default: throw BocchiDBError.invalidQuery("unsupported operator: \(op)")
        }
    }
}

extension Selector.Operator {
    func matches(_ value: JSONValue, _ compare: (JSONValue, JSONValue) -> ComparisonResult) -> Bool {
        func equal(_ a: JSONValue, _ b: JSONValue) -> Bool { compare(a, b) == .orderedSame }
        switch self {
        case .eq(let arg): return equal(value, arg)
        case .ne(let arg): return !equal(value, arg)
        case .gt(let arg): return compare(value, arg) == .orderedDescending
        case .gte(let arg): return compare(value, arg) != .orderedAscending
        case .lt(let arg): return compare(value, arg) == .orderedAscending
        case .lte(let arg): return compare(value, arg) != .orderedDescending
        case .in(let args):
            // 配列のフィールドは、要素のどれかが args に含まれれば一致する。
            if case .array(let elements) = value { return elements.contains { e in args.contains { equal(e, $0) } } }
            return args.contains { equal(value, $0) }
        case .nin(let args):
            if case .array(let elements) = value { return !elements.contains { e in args.contains { equal(e, $0) } } }
            return !args.contains { equal(value, $0) }
        case .all(let args):
            guard case .array(let elements) = value else { return false }
            if args.count == 1, case .array = args[0], equal(args[0], value) { return true }
            return !args.isEmpty && args.allSatisfy { arg in elements.contains { equal($0, arg) } }
        case .exists(let expected):
            return expected
        case .type(let type):
            return value.typeName == type
        case .size(let size):
            guard case .array(let elements) = value else { return false }
            return elements.count == size
        case .mod(let divisor, let remainder):
            guard case .int(let number) = value else { return false }
            return (divisor == -1 ? 0 : number % divisor) == remainder
        case .regex(let regex):
            guard case .string(let string) = value else { return false }
            return regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
        case .beginsWith(let prefix):
            guard case .string(let string) = value else { return false }
            return string.utf8.starts(with: prefix.utf8)
        case .elemMatch(let selector):
            guard case .array(let elements) = value else { return false }
            return elements.contains { selector.matches($0) }
        case .allMatch(let selector):
            guard case .array(let elements) = value, !elements.isEmpty else { return false }
            return elements.allSatisfy { selector.matches($0) }
        }
    }
}

private extension JSONValue {
    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int, .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}
