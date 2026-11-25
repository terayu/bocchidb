import CryptoKit
import Foundation

/// 索引の定義。
public struct IndexInfo: Sendable, Equatable {
    public let name: String
    public let fields: [String]
}

extension BocchiDB {
    // MARK: - 公開 API

    /// `find` の検索を速くする索引を作り、その名前を返す。
    ///
    /// CouchDB の `_index`（`type: "json"`）と同じく、指定したフィールドをすべて持つ文書だけが索引に入る。
    /// 索引は検索の候補を絞るためだけに使うので、索引の有無で `find` の結果は変わらない。
    /// 書き込みのたびには更新せず、次に `find` するときに変わった文書の分だけ反映する。
    ///
    /// - Parameter name: 省略するとフィールドから決まる名前になる。同じ名前の索引があれば置き換える。
    @discardableResult
    public func createIndex(fields: [String], name: String? = nil) throws -> String {
        try ensureWritable()
        try Self.rejectDesignIndexName(name)
        guard !fields.isEmpty else { throw BocchiDBError.invalidQuery("index fields must not be empty") }
        for field in fields { _ = try FindPlan.parsePath(field) }
        let encodedFields = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        let name = name ?? "idx-" + Insecure.MD5.hash(data: Data(encodedFields.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()

        try connection.transaction {
            let existing = try connection.query("SELECT fields FROM indexes WHERE name = ?", [.text(name)]).first?.first?.text
            guard existing != encodedFields else { return }
            try connection.run("DELETE FROM index_entries WHERE index_name = ?", [.text(name)])
            try connection.run("""
                INSERT INTO indexes (name, fields, indexed_seq) VALUES (?, ?, 0)
                ON CONFLICT (name) DO UPDATE SET fields = excluded.fields, indexed_seq = 0
                """, [.text(name), .text(encodedFields)])
        }
        try refreshIndexes()
        return name
    }

    /// 索引を削除する。なければ何もしない。
    public func deleteIndex(name: String) throws {
        try ensureWritable()
        try Self.rejectDesignIndexName(name)
        try connection.transaction {
            try connection.run("DELETE FROM index_entries WHERE index_name = ?", [.text(name)])
            try connection.run("DELETE FROM indexes WHERE name = ?", [.text(name)])
        }
    }

    /// 索引の一覧（名前順）。
    public func indexes() throws -> [IndexInfo] {
        try storedIndexes().map { IndexInfo(name: $0.name, fields: $0.fields) }
    }

    /// CouchDB の索引の定義（`language: "query"` の `_design` 文書）から、同じ索引を自動で作るかを設定する。
    ///
    /// 有効にすると、`_design` 文書の追加・変更・削除に合わせて、`find` のときに索引を作成・置き換え・削除する。
    /// 索引の名前は `_design/<文書名>/<索引名>` になり、`createIndex` や `deleteIndex` では変更できない。
    /// `partial_filter_selector` を使う索引には対応していないため作らない。
    /// 設定はファイルに保存される。無効にすると、自動で作った索引をすべて削除する。
    public func setDesignIndexesEnabled(_ enabled: Bool) throws {
        try ensureWritable()
        try connection.transaction {
            try connection.run("""
                INSERT INTO metadata (key, value) VALUES ('design_indexes', ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, [.text(enabled ? "1" : "0")])
            if !enabled { try syncDesignIndexes(desired: [:]) }
        }
        if enabled { try refreshIndexes() }
    }

    /// `_design` 文書から索引を自動で作る設定が有効か。
    public func designIndexesEnabled() throws -> Bool {
        try connection.query("SELECT value FROM metadata WHERE key = 'design_indexes'").first?.first?.text == "1"
    }

    // MARK: - 検索での利用（内部）

    struct StoredIndex {
        let name: String
        let fields: [String]
        let indexedSeq: Int64
    }

    /// `_id` の条件で、文書テーブルの `doc_id` の索引を使うときの名前（CouchDB の `_all_docs` に相当）。
    static let allDocsIndexName = "_all_docs"

    /// 索引で絞った候補の行（`SELECT doc_id, winning_rev, body, doc_pk` と同じ並び、`_id` 順）。
    /// 使える索引がなければ `nil`。候補がいちばん少ない索引を使う。
    func indexedRows(for selector: Selector) throws -> (index: String, rows: [[SQLiteValue]])? {
        if mode != .readOnly {
            // 別のプロセスが書き込み中で反映できない場合は、反映済みの索引だけを使う。
            try? refreshIndexes()
        }
        var best: (index: String, from: String, condition: String, arguments: [SQLiteValue], count: Int64)?
        func consider(_ index: String, from: String, _ condition: String, _ arguments: [SQLiteValue]) throws {
            let count = try connection.query("SELECT count(*) \(from) WHERE \(condition)", arguments)
                .first?.first?.integer ?? 0
            if best.map({ count < $0.count }) ?? true { best = (index, from, condition, arguments, count) }
        }

        let winners = "JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev"
        if let id = IndexPlanner.idCondition(for: selector) {
            try consider(Self.allDocsIndexName, from: "FROM documents d \(winners)",
                         "d.deleted = 0 AND substr(d.doc_id, 1, 8) != '_design/' AND (\(id.sql))", id.arguments)
        }
        let seq = try currentSeq()
        for index in try storedIndexes() where index.indexedSeq == seq {
            guard let paths = try? index.fields.map(FindPlan.parsePath),
                  let intervals = IndexPlanner.intervals(for: selector, fields: paths)
            else { continue }
            let (condition, arguments) = Self.rangeCondition(intervals)
            try consider(index.name, from: "FROM index_entries e JOIN documents d ON d.doc_pk = e.doc_pk \(winners)",
                         "e.index_name = ? AND d.deleted = 0 AND (\(condition))", [.text(index.name)] + arguments)
        }
        guard let best else { return nil }

        let rows = try connection.query("""
            SELECT d.doc_id, d.winning_rev, r.body, d.doc_pk \(best.from) WHERE \(best.condition) ORDER BY d.doc_id
            """, best.arguments)
        return (best.index, rows)
    }

    private static func rangeCondition(_ intervals: [KeyInterval]) -> (String, [SQLiteValue]) {
        guard !intervals.isEmpty else { return ("0", []) }
        var arguments: [SQLiteValue] = []
        let clauses = intervals.map { interval in
            arguments.append(.blob(Data(interval.lower)))
            guard let upper = interval.upper else { return "e.key >= ?" }
            arguments.append(.blob(Data(upper)))
            return "(e.key >= ? AND e.key < ?)"
        }
        return (clauses.joined(separator: " OR "), arguments)
    }

    // MARK: - _design 文書の索引

    /// `_design` 文書から自動で作った索引の名前の先頭。
    static let designIndexPrefix = "_design/"

    private static func rejectDesignIndexName(_ name: String?) throws {
        if let name, name.hasPrefix(designIndexPrefix) {
            throw BocchiDBError.invalidQuery("index names starting with _design/ are managed by design documents")
        }
    }

    /// `_design` 文書に書かれた索引（名前 → フィールドの JSON）。
    ///
    /// CouchDB の `_index` で作った索引は、次の形で保存される。
    /// `{"language": "query", "views": {"<名前>": {"map": {"partial_filter_selector": {}, ...},
    ///   "options": {"def": {"fields": ["type", {"date": "desc"}]}}}}}`
    private func designIndexDefinitions() throws -> [String: String] {
        let rows = try connection.query("""
            SELECT d.doc_id, r.body
            FROM documents d JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
            WHERE d.doc_id >= '_design/' AND d.doc_id < '_design0' AND d.deleted = 0
            """)
        var definitions: [String: String] = [:]
        for row in rows {
            guard let id = row[0].text, let data = row[1].blob,
                  let body = try? Self.decodeBody(data),
                  body["language"] == "query", case .object(let views)? = body["views"]
            else { continue }
            for (viewName, view) in views {
                guard case .object(let view) = view,
                      case .object(let options)? = view["options"], case .object(let def)? = options["def"],
                      case .array(let items)? = def["fields"], !items.isEmpty
                else { continue }
                // 条件に合う文書だけを入れる索引（partial_filter_selector）には対応していない。
                if case .object(let map)? = view["map"], case .object(let filter)? = map["partial_filter_selector"],
                   !filter.isEmpty { continue }
                // フィールドは "type" または {"type": "asc"} の形。並べ替えの向きは索引の内容に影響しない。
                let fields = items.compactMap { item -> String? in
                    switch item {
                    case .string(let field): field
                    case .object(let entry) where entry.count == 1: entry.keys.first
                    default: nil
                    }
                }
                guard fields.count == items.count, fields.allSatisfy({ (try? FindPlan.parsePath($0)) != nil }),
                      let encoded = try? JSONEncoder().encode(fields)
                else { continue }
                definitions["\(id)/\(viewName)"] = String(decoding: encoded, as: UTF8.self)
            }
        }
        return definitions
    }

    /// 自動で作った索引を `desired` に合わせる（作成・置き換え・削除）。トランザクション内で呼ぶこと。
    private func syncDesignIndexes(desired: [String: String]) throws {
        let existing = try connection.query("SELECT name, fields FROM indexes WHERE substr(name, 1, 8) = '_design/'")
            .reduce(into: [String: String]()) { result, row in
                if let name = row[0].text, let fields = row[1].text { result[name] = fields }
            }
        for name in existing.keys where desired[name] == nil {
            try connection.run("DELETE FROM index_entries WHERE index_name = ?", [.text(name)])
            try connection.run("DELETE FROM indexes WHERE name = ?", [.text(name)])
        }
        for (name, fields) in desired where existing[name] != fields {
            try connection.run("DELETE FROM index_entries WHERE index_name = ?", [.text(name)])
            try connection.run("""
                INSERT INTO indexes (name, fields, indexed_seq) VALUES (?, ?, 0)
                ON CONFLICT (name) DO UPDATE SET fields = excluded.fields, indexed_seq = 0
                """, [.text(name), .text(fields)])
        }
    }

    private func storedIndexes() throws -> [StoredIndex] {
        guard try hasIndexTables() else { return [] }
        return try connection.query("SELECT name, fields, indexed_seq FROM indexes ORDER BY name").compactMap { row in
            guard let name = row[0].text, let fields = row[1].text, let seq = row[2].integer,
                  let decoded = try? JSONDecoder().decode([String].self, from: Data(fields.utf8))
            else { return nil }
            return StoredIndex(name: name, fields: decoded, indexedSeq: seq)
        }
    }

    /// 索引のテーブルがあるか。0.0.4 以前に作られたファイルを `.readOnly` で開いた場合はない。
    private func hasIndexTables() throws -> Bool {
        !(try connection.query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'index_entries'").isEmpty)
    }

    /// 前回の反映以降に変わった文書を、すべての索引に反映する。
    func refreshIndexes() throws {
        guard try hasIndexTables() else { return }
        try connection.transaction {
            if try designIndexesEnabled() { try syncDesignIndexes(desired: try designIndexDefinitions()) }
            let seq = try currentSeq()
            for index in try storedIndexes() where index.indexedSeq < seq {
                let paths = try index.fields.map(FindPlan.parsePath)
                let changed = try connection.query("""
                    SELECT d.doc_pk, d.doc_id, d.winning_rev, d.deleted, r.body
                    FROM documents d LEFT JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
                    WHERE d.seq > ?
                    """, [.integer(index.indexedSeq)])
                for row in changed {
                    guard let docPK = row[0].integer, let id = row[1].text,
                          let rev = row[2].text.flatMap(RevisionID.init) else { continue }
                    try connection.run("DELETE FROM index_entries WHERE index_name = ? AND doc_pk = ?",
                                       [.text(index.name), .integer(docPK)])
                    guard row[3].integer == 0, !id.hasPrefix("_design/") else { continue }
                    let data = row[4].blob ?? Data()
                    let body = try Self.decodeBody(data)
                    let value = FindPlan.candidate(id: id, rev: rev, body: body, docPK: docPK).value
                    var key: IndexKey.Bytes = []
                    for path in paths {
                        guard case .found(let fieldValue) = Selector.resolve(value, path) else { key = []; break }
                        key += IndexKey.encode(fieldValue)
                    }
                    guard !key.isEmpty else { continue }
                    try connection.run("INSERT INTO index_entries (index_name, key, doc_pk) VALUES (?, ?, ?)",
                                       [.text(index.name), .blob(Data(key)), .integer(docPK)])
                }
                try connection.run("UPDATE indexes SET indexed_seq = ? WHERE name = ?",
                                   [.integer(seq), .text(index.name)])
            }
        }
    }
}
