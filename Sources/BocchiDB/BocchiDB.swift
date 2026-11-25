import CryptoKit
import Foundation
import SQLite3

/// CouchDB と同期できるローカル文書データベース。
public actor BocchiDB {
    /// ファイルを開いた方法。
    public nonisolated let mode: OpenMode
    let connection: SQLiteConnection
    private let revsLimit: Int
    private var observers: [UUID: AsyncStream<Change>.Continuation] = [:]
    /// 購読者に通知し終えた seq。
    private var notifiedSeq: Int64 = 0
    /// 直前の `find` で使った索引の名前（テスト用）。
    private(set) var lastFindIndex: String?

    /// `url` の SQLite ファイルを開く。
    ///
    /// - Parameter mode: 開き方。既定の `.create` は、ファイルがなければ作成する。
    ///   `.readWrite` と `.readOnly` は既存の BocchiDB ファイルだけを開き、そうでなければエラーになる。
    public init(url: URL, mode: OpenMode = .create, revsLimit: Int = 1000) throws {
        try self.init(path: url.path, mode: mode, revsLimit: revsLimit)
    }

    /// `path` に ":memory:" を渡すとインメモリ DB になる。
    init(path: String, mode: OpenMode = .create, revsLimit: Int = 1000) throws {
        precondition(revsLimit >= 1, "revsLimit must be at least 1")
        if mode != .create, !FileManager.default.fileExists(atPath: path) { throw BocchiDBError.fileNotFound }
        let connection: SQLiteConnection
        do {
            connection = try SQLiteConnection(path: path, mode: mode)
            if mode != .create { try Self.checkSchemaVersion(connection) }
            if mode != .readOnly { try connection.execute(Self.schema) }
        } catch let error as SQLiteError {
            throw Self.openError(from: error, path: path, mode: mode)
        }
        self.connection = connection
        self.mode = mode
        self.revsLimit = revsLimit
    }

    // MARK: - 公開 API

    /// 文書を作成または更新し、新しい rev を返す。
    ///
    /// 既存の文書を更新するときは、現在のリーフの rev を `rev` に渡す。
    /// 削除済みの文書は `rev` なしで作り直せる。
    @discardableResult
    public func put(id: String, body: JSONObject, rev: RevisionID? = nil) throws -> RevisionID {
        try ensureWritable()
        let newRev = try connection.transaction {
            try writeDocument(DocumentWrite(id: id, rev: rev, body: body))
        }
        notifyObservers()
        return newRev
    }

    /// 文書を削除し、削除 Revision の rev を返す。
    @discardableResult
    public func remove(id: String, rev: RevisionID) throws -> RevisionID {
        try ensureWritable()
        let newRev = try connection.transaction {
            try writeDocument(DocumentWrite(id: id, rev: rev, deleted: true))
        }
        notifyObservers()
        return newRev
    }

    /// 複数の文書をまとめて書き込み、文書ごとの結果を返す。
    ///
    /// 競合や検証エラーになった文書だけが失敗し、ほかの文書は保存される。
    public func bulkDocs(_ writes: [DocumentWrite]) throws -> [Result<RevisionID, BocchiDBError>] {
        try ensureWritable()
        let results = try connection.transaction {
            try writes.map { write -> Result<RevisionID, BocchiDBError> in
                do {
                    return .success(try writeDocument(write))
                } catch let error as BocchiDBError {
                    return .failure(error)
                }
            }
        }
        notifyObservers()
        return results
    }

    /// 削除されていない全文書の勝者 Revision を、ID 順に返す。
    public func allDocs() throws -> [Document] {
        try connection.query("""
            SELECT d.doc_id, d.winning_rev, d.deleted, r.body, d.doc_pk
            FROM documents d JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
            WHERE d.deleted = 0
            ORDER BY d.doc_id
            """)
            .compactMap { row in
                guard let id = row[0].text else { return nil }
                return try document(id: id, rev: row[1], deleted: row[2], body: row[3], docPK: row[4])
            }
    }

    /// `since` より後に変更された文書を seq 順に返す。
    public func changes(since: Int64 = 0, limit: Int? = nil) throws -> ChangesResult {
        let rows = try connection.query("""
            SELECT doc_pk, doc_id, deleted, seq, winning_rev
            FROM documents WHERE seq > ? ORDER BY seq LIMIT ?
            """, [.integer(since), .integer(Int64(limit ?? -1))])

        let results = try rows.compactMap { row -> Change? in
            guard let pk = row[0].integer, let id = row[1].text, let seq = row[3].integer,
                  let winner = row[4].text.flatMap(RevisionID.init)
            else { return nil }
            let others = try connection.query(
                "SELECT rev_id FROM revisions WHERE doc_pk = ? AND is_leaf = 1 AND rev_id != ?",
                [.integer(pk), .text(winner.description)])
                .compactMap { $0[0].text.flatMap(RevisionID.init) }
                .sorted(by: >)
            return Change(seq: seq, id: id, deleted: row[2].integer == 1, revs: [winner] + others)
        }
        return ChangesResult(results: results, lastSeq: results.last?.seq ?? since)
    }

    /// 勝者 Revision を返す。文書がない、または削除済みなら `nil`。
    public func get(id: String) throws -> Document? {
        let rows = try connection.query("""
            SELECT d.winning_rev, d.deleted, r.body, d.doc_pk
            FROM documents d JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
            WHERE d.doc_id = ?
            """, [.text(id)])
        guard let row = rows.first, row[1].integer == 0 else { return nil }
        return try document(id: id, rev: row[0], deleted: row[1], body: row[2], docPK: row[3])
    }

    /// 指定したリーフ Revision を返す。本文を保持していない（リーフでない）場合は `nil`。
    public func get(id: String, rev: RevisionID) throws -> Document? {
        let rows = try connection.query("""
            SELECT r.rev_id, r.deleted, r.body, r.doc_pk
            FROM revisions r JOIN documents d ON d.doc_pk = r.doc_pk
            WHERE d.doc_id = ? AND r.rev_id = ? AND r.body IS NOT NULL
            """, [.text(id), .text(rev.description)])
        guard let row = rows.first else { return nil }
        return try document(id: id, rev: row[0], deleted: row[1], body: row[2], docPK: row[3])
    }

    /// 勝者以外の、削除されていないリーフ（競合）を返す。
    public func conflicts(id: String) throws -> [RevisionID] {
        try connection.query("""
            SELECT r.rev_id
            FROM revisions r JOIN documents d ON d.doc_pk = r.doc_pk
            WHERE d.doc_id = ? AND r.is_leaf = 1 AND r.deleted = 0 AND r.rev_id != d.winning_rev
            """, [.text(id)])
            .compactMap { $0[0].text.flatMap(RevisionID.init) }
            .sorted(by: >)
    }

    /// Mango クエリ（CouchDB の `_find` 相当）で文書を検索する。
    ///
    /// 削除されていない文書の勝者 Revision が対象で、`_design/` の文書は含まない。
    /// 使える索引（`createIndex`）があれば候補を絞り、なければ全文書を読んで照合する。結果はどちらでも同じ。
    public func find(_ query: FindQuery) throws -> [Document] {
        try find(query, useIndexes: true)
    }

    func find(_ query: FindQuery, useIndexes: Bool) throws -> [Document] {
        let plan = try FindPlan(query)
        let indexed = useIndexes ? try indexedRows(for: plan.selector) : nil
        lastFindIndex = indexed?.index
        let rows = try indexed?.rows ?? connection.query("""
            SELECT d.doc_id, d.winning_rev, r.body, d.doc_pk
            FROM documents d JOIN revisions r ON r.doc_pk = d.doc_pk AND r.rev_id = d.winning_rev
            WHERE d.deleted = 0 AND substr(d.doc_id, 1, 8) != '_design/'
            ORDER BY d.doc_id
            """)
        let candidates = try rows.compactMap { row -> FindPlan.Candidate? in
            guard let id = row[0].text, let rev = row[1].text.flatMap(RevisionID.init),
                  let data = row[2].blob, let docPK = row[3].integer
            else { return nil }
            let body = try Self.decodeBody(data)
            let candidate = FindPlan.candidate(id: id, rev: rev, body: body, docPK: docPK)
            return plan.matches(candidate) ? candidate : nil
        }
        return try plan.arrange(candidates).map { candidate in
            Document(id: candidate.id, rev: candidate.rev, deleted: false, body: plan.project(candidate.body),
                     attachments: plan.includesAttachments ? try loadAttachments(docPK: candidate.docPK, rev: candidate.rev) : [:])
        }
    }

    // MARK: - 保守

    /// ファイルを作り直し、削除などで空いた領域を返してファイルを小さくする。
    ///
    /// 削除した文書の本文や使われなくなった添付は書き込み時に消えており、その領域は次の書き込みで再利用される。
    /// この処理は、ファイルの大きさ自体を縮めたいときにだけ使う。
    /// 実行中はほかの書き込みを待たせ、一時的に DB と同じくらいの空き容量を使う。
    /// 別の接続が読み取り中だと、`-wal` の内容を本体に移しきれず、ファイルが小さくなるのは次の機会になる。
    public func compact() throws {
        try ensureWritable()
        try connection.execute("VACUUM")
        try connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    // MARK: - 添付ファイル

    /// 添付ファイルを追加または置き換え、新しい rev を返す。本文とほかの添付はそのまま引き継ぐ。
    ///
    /// 文書がなければ、本文が空の文書として作成する（`rev` は `nil`）。
    @discardableResult
    public func putAttachment(
        id: String, name: String, contentType: String, data: Data, rev: RevisionID? = nil
    ) throws -> RevisionID {
        try ensureWritable()
        let newRev = try connection.transaction {
            let body = try rev.flatMap { try get(id: id, rev: $0)?.body } ?? [:]
            return try writeDocument(DocumentWrite(id: id, rev: rev, body: body),
                                     edit: .put(name: name, contentType: contentType, data: data))
        }
        notifyObservers()
        return newRev
    }

    /// 添付ファイルを削除し、新しい rev を返す。
    @discardableResult
    public func removeAttachment(id: String, name: String, rev: RevisionID) throws -> RevisionID {
        try ensureWritable()
        let newRev = try connection.transaction {
            let body = try get(id: id, rev: rev)?.body ?? [:]
            return try writeDocument(DocumentWrite(id: id, rev: rev, body: body), edit: .remove(name: name))
        }
        notifyObservers()
        return newRev
    }

    /// 添付ファイルのデータを返す。`rev` を省略すると勝者 Revision のもの。
    public func attachment(id: String, name: String, rev: RevisionID? = nil) throws -> Data? {
        let revCondition = rev == nil ? "ra.rev_id = d.winning_rev AND d.deleted = 0" : "ra.rev_id = ?"
        var arguments: [SQLiteValue] = [.text(id), .text(name)]
        if let rev { arguments.append(.text(rev.description)) }
        return try connection.query("""
            SELECT b.data
            FROM documents d
            JOIN revision_attachments ra ON ra.doc_pk = d.doc_pk
            JOIN attachment_blobs b ON b.digest = ra.digest
            WHERE d.doc_id = ? AND ra.name = ? AND \(revCondition)
            """, arguments).first?.first?.blob
    }

    // MARK: - 変更の通知

    /// これ以降の変更を流すストリームを返す。保存による変更も、同期で取り込んだ変更も含む。
    ///
    /// 購読より前の変更は流れない。それ以前の変更が必要なら `changes(since:)` を使う。
    /// ストリームの反復を終えると（タスクのキャンセルなど）購読は自動的に解除される。
    public func observeChanges() -> AsyncStream<Change> {
        observeChanges(bufferingPolicy: .unbounded)
    }

    func observeChanges(bufferingPolicy: AsyncStream<Change>.Continuation.BufferingPolicy) -> AsyncStream<Change> {
        if observers.isEmpty {
            // 購読者がいない間は通知位置を進めていないので、現在の位置から始める。
            notifiedSeq = (try? currentSeq()) ?? notifiedSeq
        }
        let id = UUID()
        let (stream, continuation) = AsyncStream<Change>.makeStream(bufferingPolicy: bufferingPolicy)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        return stream
    }

    /// 現在の購読者数（テスト用）。
    var observerCount: Int { observers.count }

    private func removeObserver(_ id: UUID) {
        observers[id] = nil
    }

    /// 書き込みの確定後に呼ぶ。前回の通知以降の変更を全購読者に流す。
    ///
    /// 読み込みに失敗しても書き込み自体は成功しているので、エラーは投げない（次の書き込みでまとめて流れる）。
    private func notifyObservers() {
        guard !observers.isEmpty, let changes = try? changes(since: notifiedSeq) else { return }
        for change in changes.results {
            for continuation in observers.values { continuation.yield(change) }
        }
        notifiedSeq = changes.lastSeq
    }

    func currentSeq() throws -> Int64 {
        try connection.query("SELECT coalesce(max(seq), 0) FROM documents").first?.first?.integer ?? 0
    }

    // MARK: - レプリケーション用（内部）

    /// 履歴付きの Revision をそのまま取り込む（CouchDB の `new_edits=false` に相当）。
    ///
    /// - Parameter path: 取り込む Revision とその祖先（新しい順）。
    /// - Returns: 新しい Revision を追加した場合は `true`。すでにあれば `false`。
    ///   - attachments: 添付。stub（`data` が `nil`）は、ローカルの祖先 Revision から名前と revpos で探す。
    @discardableResult
    func merge(
        id: String, path: [RevisionID], deleted: Bool, body: JSONObject,
        attachments incoming: [String: IncomingAttachment] = [:]
    ) throws -> Bool {
        try ensureWritable()
        try Self.validate(id: id, body: body)
        let changed = try connection.transaction {
            var (docPK, tree) = try loadTree(id: id)
            if let newest = path.first, tree.contains(newest) { return false }  // 取り込み済み

            var attachments: [String: AttachmentInfo] = [:]
            var blobs: [String: Data] = [:]
            for (name, attachment) in incoming {
                if let data = attachment.data {
                    let digest = AttachmentInfo.digest(of: data)
                    blobs[digest] = data
                    attachments[name] = AttachmentInfo(contentType: attachment.contentType, digest: digest,
                                                       length: data.count, revpos: attachment.revpos)
                } else {
                    // CouchDB の stub の digest はローカルの digest と一致しないことがあるため、名前と revpos で探す。
                    guard let docPK, let row = try connection.query("""
                        SELECT digest, length FROM revision_attachments WHERE doc_pk = ? AND name = ? AND revpos = ? LIMIT 1
                        """, [.integer(docPK), .text(name), .integer(Int64(attachment.revpos))]).first,
                        let digest = row[0].text, let length = row[1].integer
                    else { throw BocchiDBError.invalidAttachment(name) }
                    attachments[name] = AttachmentInfo(contentType: attachment.contentType, digest: digest,
                                                       length: Int(length), revpos: attachment.revpos)
                }
            }
            return try apply(id: id, docPK: docPK, tree: &tree, path: path, deleted: deleted, body: body,
                             attachments: attachments, blobs: blobs)
        }
        if changed { notifyObservers() }
        return changed
    }

    /// 文書の全リーフ（`_bulk_get` の `atts_since` に使う）。
    func leafRevisions(id: String) throws -> [RevisionID] {
        try connection.query("""
            SELECT r.rev_id FROM revisions r JOIN documents d ON d.doc_pk = r.doc_pk
            WHERE d.doc_id = ? AND r.is_leaf = 1
            """, [.text(id)]).compactMap { $0[0].text.flatMap(RevisionID.init) }
    }

    /// 保存している添付データの数（テスト用）。
    func attachmentBlobCount() throws -> Int {
        Int(try connection.query("SELECT count(*) FROM attachment_blobs").first?.first?.integer ?? 0)
    }

    /// DB ごとに一意な UUID（Replication ID の算出に使う）。
    func uuid() throws -> String {
        try connection.scalarText("SELECT value FROM metadata WHERE key = 'db_uuid'") ?? ""
    }

    /// 指定した rev のうち、ローカルに存在しないものを返す（`_revs_diff` 相当）。
    func missingRevisions(_ revsByID: [String: [RevisionID]]) throws -> [String: [RevisionID]] {
        var missing: [String: [RevisionID]] = [:]
        for (id, revs) in revsByID {
            for rev in revs {
                let exists = try connection.query("""
                    SELECT 1 FROM revisions r JOIN documents d ON d.doc_pk = r.doc_pk
                    WHERE d.doc_id = ? AND r.rev_id = ?
                    """, [.text(id), .text(rev.description)])
                if exists.isEmpty { missing[id, default: []].append(rev) }
            }
        }
        return missing
    }

    /// `rev` から祖先をたどった履歴（新しい順、`rev` 自身を含む）。
    func revisionHistory(id: String, rev: RevisionID) throws -> [RevisionID] {
        let tree = try loadTree(id: id).tree
        guard tree.contains(rev) else { return [] }
        var history = [rev]
        while let parent = tree.parent(of: history[history.count - 1]) {
            history.append(parent)
        }
        return history
    }

    /// `_local` 文書を返す。Revision Tree を持たず、Changes やレプリケーションの対象にならない。
    func getLocal(id: String) throws -> JSONObject? {
        guard let data = try connection.query("SELECT body FROM local_docs WHERE doc_id = ?", [.text(id)])
            .first?.first?.blob
        else { return nil }
        return try Self.decodeBody(data)
    }

    /// `_local` 文書を作成または上書きする。rev は CouchDB と同じ "0-N" 形式で増やす。
    func putLocal(id: String, body: JSONObject) throws {
        try ensureWritable()
        try connection.run("""
            INSERT INTO local_docs (doc_id, rev, body) VALUES (?, '0-1', ?)
            ON CONFLICT (doc_id) DO UPDATE
            SET rev = '0-' || (CAST(substr(rev, 3) AS INTEGER) + 1), body = excluded.body
            """, [.text(id), .blob(try Self.encode(body))])
    }

    func removeLocal(id: String) throws {
        try ensureWritable()
        try connection.run("DELETE FROM local_docs WHERE doc_id = ?", [.text(id)])
    }

    /// 文書が保持している Revision の数（テスト用）。
    func revisionCount(id: String) throws -> Int {
        let rows = try connection.query("""
            SELECT count(*) FROM revisions r JOIN documents d ON d.doc_pk = r.doc_pk WHERE d.doc_id = ?
            """, [.text(id)])
        return Int(rows.first?.first?.integer ?? 0)
    }

    // MARK: - 書き込み

    func ensureWritable() throws {
        if mode == .readOnly { throw BocchiDBError.readOnly }
    }

    /// 書き込み時の添付の扱い。指定がなければ親 Revision の添付を引き継ぐ。
    private enum AttachmentEdit {
        case keep
        case put(name: String, contentType: String, data: Data)
        case remove(name: String)
    }

    /// 新しい Revision を 1 件書き込む。トランザクション内で呼ぶこと。
    ///
    /// `BocchiDBError` は SQLite に書き込む前に投げるので、失敗しても途中までの書き込みは残らない。
    private func writeDocument(_ write: DocumentWrite, edit: AttachmentEdit = .keep) throws -> RevisionID {
        try Self.validate(id: write.id, body: write.body)
        var (docPK, tree) = try loadTree(id: write.id)

        let parent: RevisionID?
        if let parentRev = write.rev {
            guard tree.isLeaf(parentRev) else { throw BocchiDBError.conflict }
            parent = parentRev
        } else if let winner = winningRevision(of: tree.leaves) {
            guard winner.deleted else { throw BocchiDBError.conflict }
            parent = winner.rev  // 削除済み文書の作り直し
        } else {
            parent = nil
        }

        // 削除 Revision は添付を持たない。
        var attachments: [String: AttachmentInfo] = [:]
        if !write.deleted, let docPK, let parent {
            attachments = try loadAttachments(docPK: docPK, rev: parent)
        }
        var blobs: [String: Data] = [:]
        switch edit {
        case .keep:
            break
        case .put(let name, let contentType, let data):
            guard !name.isEmpty, !name.hasPrefix("_") else { throw BocchiDBError.invalidAttachment(name) }
            let digest = AttachmentInfo.digest(of: data)
            blobs[digest] = data
            attachments[name] = AttachmentInfo(contentType: contentType, digest: digest, length: data.count,
                                               revpos: (parent?.generation ?? 0) + 1)
        case .remove(let name):
            guard attachments.removeValue(forKey: name) != nil else { throw BocchiDBError.attachmentNotFound(name) }
        }

        let newRev = try Self.makeRevision(parent: parent, deleted: write.deleted, body: write.body, attachments: attachments)
        let path = [newRev] + (parent.map { [$0] } ?? [])
        try apply(id: write.id, docPK: docPK, tree: &tree, path: path, deleted: write.deleted, body: write.body,
                  attachments: attachments, blobs: blobs)
        return newRev
    }

    /// Revision Tree に `path` を取り込み、変化した行だけを SQLite に反映する。
    @discardableResult
    private func apply(
        id: String, docPK: Int64?, tree: inout RevisionTree,
        path: [RevisionID], deleted: Bool, body: JSONObject,
        attachments: [String: AttachmentInfo] = [:], blobs: [String: Data] = [:]
    ) throws -> Bool {
        let leavesBefore = Set(tree.leaves.map(\.rev))
        let inserted = try tree.merge(path: path, deleted: deleted)
        guard !inserted.isEmpty else { return false }
        let stemmed = tree.stem(limit: revsLimit)

        let pk = try docPK ?? insertDocumentRow(id: id)
        let bodyData = try Self.encode(body)

        // 古い順に挿入するので、最新の Revision が最大の seq を持つ。
        for rev in inserted where tree.contains(rev) {
            try connection.run("""
                INSERT INTO revisions (doc_pk, rev_id, generation, parent_rev, deleted, is_leaf, body)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, [
                    .integer(pk), .text(rev.description), .integer(Int64(rev.generation)),
                    tree.parent(of: rev).map { .text($0.description) } ?? .null,
                    .integer(tree.isDeleted(rev) ? 1 : 0),
                    .integer(tree.isLeaf(rev) ? 1 : 0),
                    rev == path[0] ? .blob(bodyData) : .null,
                ])
        }
        if inserted.contains(path[0]) {
            for (digest, data) in blobs {
                try connection.run("INSERT OR IGNORE INTO attachment_blobs (digest, data) VALUES (?, ?)",
                                   [.text(digest), .blob(data)])
            }
            for (name, info) in attachments {
                try connection.run("""
                    INSERT INTO revision_attachments (doc_pk, rev_id, name, content_type, digest, length, revpos)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, [.integer(pk), .text(path[0].description), .text(name), .text(info.contentType),
                          .text(info.digest), .integer(Int64(info.length)), .integer(Int64(info.revpos))])
            }
        }
        for rev in stemmed.removed {
            try connection.run("DELETE FROM revisions WHERE doc_pk = ? AND rev_id = ?",
                               [.integer(pk), .text(rev.description)])
        }
        for rev in stemmed.newRoots {
            try connection.run("UPDATE revisions SET parent_rev = NULL WHERE doc_pk = ? AND rev_id = ?",
                               [.integer(pk), .text(rev.description)])
        }
        // リーフでなくなった Revision は本文と添付を破棄し、どこからも参照されない添付データを消す。
        var demoted = false
        for rev in leavesBefore where tree.contains(rev) && !tree.isLeaf(rev) {
            try connection.run("UPDATE revisions SET is_leaf = 0, body = NULL WHERE doc_pk = ? AND rev_id = ?",
                               [.integer(pk), .text(rev.description)])
            try connection.run("DELETE FROM revision_attachments WHERE doc_pk = ? AND rev_id = ?",
                               [.integer(pk), .text(rev.description)])
            demoted = true
        }
        if demoted {
            try connection.run(
                "DELETE FROM attachment_blobs WHERE digest NOT IN (SELECT digest FROM revision_attachments)")
        }

        guard let winner = winningRevision(of: tree.leaves) else { return true }
        try connection.run("""
            UPDATE documents
            SET winning_rev = ?, deleted = ?, seq = (SELECT max(seq) FROM revisions WHERE doc_pk = ?)
            WHERE doc_pk = ?
            """, [.text(winner.rev.description), .integer(winner.deleted ? 1 : 0), .integer(pk), .integer(pk)])
        return true
    }

    private func loadTree(id: String) throws -> (docPK: Int64?, tree: RevisionTree) {
        guard let docPK = try connection.query("SELECT doc_pk FROM documents WHERE doc_id = ?", [.text(id)])
            .first?.first?.integer
        else { return (nil, RevisionTree()) }

        var nodes: [RevisionID: RevisionTree.Node] = [:]
        for row in try connection.query(
            "SELECT rev_id, parent_rev, deleted FROM revisions WHERE doc_pk = ?", [.integer(docPK)])
        {
            guard let rev = row[0].text.flatMap(RevisionID.init) else { continue }
            nodes[rev] = .init(parent: row[1].text.flatMap(RevisionID.init), deleted: row[2].integer == 1)
        }
        return (docPK, RevisionTree(nodes: nodes))
    }

    private func loadAttachments(docPK: Int64, rev: RevisionID) throws -> [String: AttachmentInfo] {
        var attachments: [String: AttachmentInfo] = [:]
        for row in try connection.query("""
            SELECT name, content_type, digest, length, revpos FROM revision_attachments WHERE doc_pk = ? AND rev_id = ?
            """, [.integer(docPK), .text(rev.description)]) {
            guard let name = row[0].text, let contentType = row[1].text, let digest = row[2].text,
                  let length = row[3].integer, let revpos = row[4].integer else { continue }
            attachments[name] = AttachmentInfo(contentType: contentType, digest: digest,
                                               length: Int(length), revpos: Int(revpos))
        }
        return attachments
    }

    private func insertDocumentRow(id: String) throws -> Int64 {
        let rows = try connection.query(
            "INSERT INTO documents (doc_id, winning_rev, deleted, seq) VALUES (?, '', 0, 0) RETURNING doc_pk",
            [.text(id)])
        guard let pk = rows.first?.first?.integer else {
            throw SQLiteError(code: -1, message: "failed to insert document row")
        }
        return pk
    }

    // MARK: - ヘルパー

    private static func validate(id: String, body: JSONObject) throws {
        if id.isEmpty || (id.hasPrefix("_") && !id.hasPrefix("_design/")) {
            throw BocchiDBError.invalidDocumentID(id)
        }
        if let key = body.keys.filter({ $0.hasPrefix("_") }).min() {
            throw BocchiDBError.invalidBody(key)
        }
    }

    /// 親 rev・削除フラグ・本文・添付から決定的に rev を生成する。
    private static func makeRevision(
        parent: RevisionID?, deleted: Bool, body: JSONObject, attachments: [String: AttachmentInfo]
    ) throws -> RevisionID {
        var input = Data((parent?.description ?? "").utf8)
        input.append(contentsOf: deleted ? [0, 1] : [0, 0])
        input.append(try encode(body))
        for (name, info) in attachments.sorted(by: { $0.key < $1.key }) {
            input.append(Data("\u{0}\(name)\u{0}\(info.digest)".utf8))
        }
        let hash = Insecure.MD5.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return RevisionID("\((parent?.generation ?? 0) + 1)-\(hash)")!
    }

    /// 本文はキーの記述順のまま保存する（CouchDB と同じ順序で比べるため）。
    private static func encode(_ body: JSONObject) throws -> Data {
        try JSONValue.object(body).jsonData()
    }

    static func decodeBody(_ data: Data) throws -> JSONObject {
        if data.isEmpty { return [:] }
        guard case .object(let body) = try JSONValue(json: data) else {
            throw BocchiDBError.invalidJSON("document body is not an object")
        }
        return body
    }

    private func document(
        id: String, rev: SQLiteValue, deleted: SQLiteValue, body: SQLiteValue, docPK: SQLiteValue
    ) throws -> Document? {
        guard let rev = rev.text.flatMap(RevisionID.init), let data = body.blob, let docPK = docPK.integer else { return nil }
        let decoded = try Self.decodeBody(data)
        return Document(id: id, rev: rev, deleted: deleted.integer == 1, body: decoded,
                        attachments: try loadAttachments(docPK: docPK, rev: rev))
    }

    private static let schemaVersion = "1"

    /// 開くときの SQLite のエラーを、原因が分かるものは `BocchiDBError` に変換する。
    ///
    /// SQLite は権限の問題を専用のコードで返さない（`SQLITE_CANTOPEN` や `SQLITE_READONLY` になる）ため、
    /// ファイルとフォルダの状態を調べて、権限が原因と確認できた場合だけ `permissionDenied` にする。
    private static func openError(from error: SQLiteError, path: String, mode: OpenMode) -> any Error {
        let fileManager = FileManager.default
        switch error.code {
        case SQLITE_NOTADB:
            return BocchiDBError.unsupportedDatabase("not an SQLite database")
        case SQLITE_CANTOPEN where mode == .readOnly && !fileManager.fileExists(atPath: path + "-wal"):
            return BocchiDBError.walFileMissing
        case SQLITE_CANTOPEN, SQLITE_READONLY, SQLITE_PERM:
            let directory = (path as NSString).deletingLastPathComponent
            let exists = fileManager.fileExists(atPath: path)
            // 開くときに作る必要があるファイル。読み取り専用の接続は -shm だけを作る。
            let filesToCreate = (exists ? [] : [path]) + (mode == .readOnly ? ["-shm"] : ["-wal", "-shm"])
                .map { path + $0 }.filter { !fileManager.fileExists(atPath: $0) }
            let denied = (exists && !fileManager.isReadableFile(atPath: path))
                || (exists && mode != .readOnly && !fileManager.isWritableFile(atPath: path))
                || (!filesToCreate.isEmpty && !fileManager.isWritableFile(atPath: directory))
            return denied ? BocchiDBError.permissionDenied : error
        default:
            return error
        }
    }

    /// 既存のファイルが、このバージョンで扱える BocchiDB のデータベースか確かめる。
    private static func checkSchemaVersion(_ connection: SQLiteConnection) throws {
        let hasMetadata = !(try connection.query(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'metadata'").isEmpty)
        guard hasMetadata,
              let version = try connection.scalarText("SELECT value FROM metadata WHERE key = 'schema_version'")
        else { throw BocchiDBError.unsupportedDatabase("not a BocchiDB database") }
        guard version == schemaVersion else {
            throw BocchiDBError.unsupportedDatabase("unsupported schema version \(version)")
        }
    }

    private static let schema = """
        PRAGMA journal_mode = WAL;

        CREATE TABLE IF NOT EXISTS documents (
          doc_pk      INTEGER PRIMARY KEY,
          doc_id      TEXT NOT NULL UNIQUE,
          winning_rev TEXT NOT NULL,
          deleted     INTEGER NOT NULL,
          seq         INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS revisions (
          seq         INTEGER PRIMARY KEY AUTOINCREMENT,
          doc_pk      INTEGER NOT NULL REFERENCES documents(doc_pk),
          rev_id      TEXT NOT NULL,
          generation  INTEGER NOT NULL,
          parent_rev  TEXT,
          deleted     INTEGER NOT NULL,
          is_leaf     INTEGER NOT NULL,
          body        BLOB,
          UNIQUE (doc_pk, rev_id)
        );

        -- 添付データ。digest（元データの MD5）で重複を除いて 1 つだけ保存する。
        CREATE TABLE IF NOT EXISTS attachment_blobs (
          digest TEXT PRIMARY KEY,
          data   BLOB NOT NULL
        );

        -- リーフ Revision ごとの添付
        CREATE TABLE IF NOT EXISTS revision_attachments (
          doc_pk       INTEGER NOT NULL REFERENCES documents(doc_pk),
          rev_id       TEXT NOT NULL,
          name         TEXT NOT NULL,
          content_type TEXT NOT NULL,
          digest       TEXT NOT NULL,
          length       INTEGER NOT NULL,
          revpos       INTEGER NOT NULL,
          PRIMARY KEY (doc_pk, rev_id, name)
        );
        CREATE INDEX IF NOT EXISTS revision_attachments_digest ON revision_attachments (digest);

        CREATE TABLE IF NOT EXISTS local_docs (
          doc_id TEXT PRIMARY KEY,
          rev    TEXT NOT NULL,
          body   BLOB NOT NULL
        );

        -- Mango クエリの索引。キーの形式は IndexKey を参照。検索時に indexed_seq 以降の変更を反映する。
        CREATE TABLE IF NOT EXISTS indexes (
          name        TEXT PRIMARY KEY,
          fields      TEXT NOT NULL,
          indexed_seq INTEGER NOT NULL
        );

        CREATE TABLE IF NOT EXISTS index_entries (
          index_name TEXT NOT NULL,
          key        BLOB NOT NULL,
          doc_pk     INTEGER NOT NULL,
          PRIMARY KEY (index_name, key, doc_pk)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS index_entries_doc ON index_entries (index_name, doc_pk);

        CREATE TABLE IF NOT EXISTS metadata (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );

        INSERT OR IGNORE INTO metadata (key, value) VALUES ('schema_version', '\(schemaVersion)');
        INSERT OR IGNORE INTO metadata (key, value) VALUES ('db_uuid', lower(hex(randomblob(16))));
        """
}
