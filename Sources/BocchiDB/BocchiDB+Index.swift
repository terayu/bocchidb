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
        try connection.transaction {
            try connection.run("DELETE FROM index_entries WHERE index_name = ?", [.text(name)])
            try connection.run("DELETE FROM indexes WHERE name = ?", [.text(name)])
        }
    }

    /// 索引の一覧（名前順）。
    public func indexes() throws -> [IndexInfo] {
        try storedIndexes().map { IndexInfo(name: $0.name, fields: $0.fields) }
    }

    // MARK: - 検索での利用（内部）

    struct StoredIndex {
        let name: String
        let fields: [String]
        let indexedSeq: Int64
    }

    /// 索引で絞った候補の行（`SELECT doc_id, winning_rev, body, doc_pk` と同じ並び、`_id` 順）。
    /// 使える索引がなければ `nil`。
    func indexedRows(for selector: Selector) throws -> (index: String, rows: [[SQLiteValue]])? {
        if mode != .readOnly {
            // 別のプロセスが書き込み中で反映できない場合は、反映済みの索引だけを使う。
            try? refreshIndexes()
        }
        let seq = try currentSeq()
        var best: (index: String, intervals: [KeyInterval], count: Int64)?
        for index in try storedIndexes() where index.indexedSeq == seq {
            guard let paths = try? index.fields.map(FindPlan.parsePath),
                  let intervals = IndexPlanner.intervals(for: selector, fields: paths)
            else { continue }
            let (condition, arguments) = Self.rangeCondition(intervals)
            let count = try connection.query(
                "SELECT count(*) FROM index_entries e WHERE e.index_name = ? AND (\(condition))",
                [.text(index.name)] + arguments).first?.first?.integer ?? 0
            if best.map({ count < $0.count }) ?? true { best = (index.name, intervals, count) }
        }
        guard let best else { return nil }

        let (condition, arguments) = Self.rangeCondition(best.intervals)
        let rows = try connection.query("""
            SELECT d.doc_id, d.winning_rev, r.body, d.doc_pk
            FROM index_entries e
            JOIN documents d ON d.doc_pk = e.doc_pk
            JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
            WHERE e.index_name = ? AND d.deleted = 0 AND (\(condition))
            ORDER BY d.doc_id
            """, [.text(best.index)] + arguments)
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
                    let body = data.isEmpty ? [:] : try JSONDecoder().decode([String: JSONValue].self, from: data)
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
