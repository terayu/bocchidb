import CryptoKit
import Foundation

/// 1 回のレプリケーションの結果。
public struct ReplicationResult: Sendable, Equatable {
    /// 転送先に書き込んだ Revision の数。
    public var docsWritten = 0
}

/// ローカルの BocchiDB と CouchDB の 1 データベースを同期する。
public struct Replicator: Sendable {
    public let local: BocchiDB
    public let remote: URL
    private let client: CouchClient
    private let batchSize: Int

    /// - Parameters:
    ///   - remote: CouchDB のデータベース URL（例: `https://example.com/inspections`）。
    ///   - batchSize: 1 回の `_changes` で扱う文書数。
    ///   - retryPolicy: 通信エラーや HTTP 5xx / 429 に対する再試行の設定。
    public init(
        local: BocchiDB, remote: URL, auth: Authentication = .none,
        batchSize: Int = 100, retryPolicy: RetryPolicy = .default, session: URLSession = .shared
    ) {
        precondition(batchSize >= 1, "batchSize must be at least 1")
        self.local = local
        self.remote = remote
        self.client = CouchClient(databaseURL: remote, auth: auth, session: session, retryPolicy: retryPolicy)
        self.batchSize = batchSize
    }

    /// CouchDB → ローカル。
    @discardableResult
    public func pull() async throws -> ReplicationResult {
        var checkpoint = try await loadCheckpoint(direction: "pull")
        var since = checkpoint.since ?? .int(0)
        return ReplicationResult(docsWritten: try await pullBatches(&checkpoint, since: &since, longpoll: false) {})
    }

    /// ローカル → CouchDB。
    @discardableResult
    public func push() async throws -> ReplicationResult {
        var checkpoint = try await loadCheckpoint(direction: "push")
        var since: Int64 = if case .int(let seq) = checkpoint.since { seq } else { 0 }
        return ReplicationResult(docsWritten: try await pushBatches(&checkpoint, since: &since) {})
    }

    /// push してから pull する。
    @discardableResult
    public func sync() async throws -> (push: ReplicationResult, pull: ReplicationResult) {
        let pushed = try await push()
        let pulled = try await pull()
        return (pushed, pulled)
    }

    /// キャンセルされるまで、双方向に同期し続ける（Live Sync）。
    ///
    /// - CouchDB の変更は longpoll で待ち、届いたらすぐ取り込む。
    /// - ローカルの変更は通知を受けたらすぐ送る。
    /// - 通信エラーや HTTP 5xx / 429 では止まらず、待ってから再開する（オフラインからの復帰）。
    /// - 認証エラーなど一時的でないエラーでは、そのエラーを投げて止まる。
    ///
    /// タスクをキャンセルすると、待機中の longpoll も含めてすぐに終わる（エラーは投げない）。
    /// アプリがバックグラウンドに移るときにキャンセルし、フォアグラウンドに戻ったら再び呼ぶ使い方を想定している。
    ///
    /// - Parameter onStatus: 同期状態が変わるたびに呼ばれる。呼び出しは 1 つずつ順番に行われる。
    ///   最後は必ず `.stopped` になる。エラーで止まった場合、その内容は `live()` が投げるエラーで分かる。
    ///
    /// SwiftUI では、`AsyncStream` を介して MainActor で順に受け取ると扱いやすい。
    /// ```swift
    /// let (statuses, continuation) = AsyncStream.makeStream(of: SyncStatus.self)
    /// Task { try await replicator.live { continuation.yield($0) } }
    /// for await status in statuses { model.status = status }  // MainActor 上で
    /// ```
    public func live(onStatus: @escaping @Sendable (SyncStatus) -> Void = { _ in }) async throws {
        let status = StatusTracker(handler: onStatus)
        await status.start()
        // 最初の push より前に購読し、その間のローカル変更を取りこぼさない。
        // push はチェックポイントから読むので、通知は「変更があった」ことだけ分かればよい（最新 1 件だけ保持）。
        let localChanges = await local.observeChanges(bufferingPolicy: .bufferingNewest(1))
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await livePull(status) }
                group.addTask { try await livePush(localChanges, status) }
                try await group.next()
                group.cancelAll()
            }
        } catch where Task.isCancelled {
            await status.stop()
            return
        } catch {
            await status.stop()
            throw error
        }
    }

    // MARK: - Live Sync

    private func livePull(_ status: StatusTracker) async throws {
        var checkpoint = try await keepAlive(.pull, status) { try await loadCheckpoint(direction: "pull") }
        var since = checkpoint.since ?? .int(0)
        // 最初の 1 回とオフラインからの復帰直後は longpoll を使わない。
        // longpoll は変更がないと最大 25 秒待つため、その間 connecting / offline の表示が残ってしまう。
        var longpoll = false
        while true {
            try Task.checkCancellation()
            _ = try await keepAlive(.pull, status, onFailure: { longpoll = false }) {
                try await pullBatches(&checkpoint, since: &since, longpoll: longpoll) {
                    await status.set(.pull, .active)
                }
            }
            longpoll = true
            await status.set(.pull, .idle)
        }
    }

    private func livePush(_ localChanges: AsyncStream<Change>, _ status: StatusTracker) async throws {
        var checkpoint = try await keepAlive(.push, status) { try await loadCheckpoint(direction: "push") }
        var since: Int64 = if case .int(let seq) = checkpoint.since { seq } else { 0 }
        var changes = localChanges.makeAsyncIterator()
        while true {
            _ = try await keepAlive(.push, status) {
                try await pushBatches(&checkpoint, since: &since) { await status.set(.push, .active) }
            }
            await status.set(.push, .idle)
            // 次のローカル変更を待つ。キャンセルされると nil が返る。
            guard await changes.next() != nil else { throw CancellationError() }
        }
    }

    /// 一時的なエラーのあいだは `offline` を知らせ、待ちながら `operation` を繰り返す。
    private func keepAlive<T>(
        _ side: StatusTracker.Side, _ status: StatusTracker,
        onFailure: () -> Void = {}, _ operation: () async throws -> T
    ) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await operation()
            } catch where Self.isTransient(error) && !Task.isCancelled {
                onFailure()
                await status.set(side, .offline)
                failures += 1
                let delay = client.retryPolicy.delay(afterAttempt: min(failures, 30))
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    private static func isTransient(_ error: any Error) -> Bool {
        switch error {
        case let error as URLError: RetryPolicy.isRetryable(error)
        case ReplicationError.http(let status, _): RetryPolicy.isRetryable(status: status)
        case ReplicationError.malformedResponse: true
        default: false
        }
    }

    // MARK: - バッチ処理

    private func loadCheckpoint(direction: String) async throws -> Checkpoint {
        try await Checkpoint.load(id: try await replicationID(direction: direction), local: local, client: client)
    }

    /// 追いつくまで CouchDB の変更を取り込み、書き込んだ Revision の数を返す。
    ///
    /// - Parameter onTransfer: 実際に文書を取得する直前に呼ばれる。
    private func pullBatches(
        _ checkpoint: inout Checkpoint, since: inout JSONValue, longpoll: Bool, onTransfer: () async -> Void
    ) async throws -> Int {
        var written = 0
        while true {
            try Task.checkCancellation()
            let feed = try await client.changes(since: since, limit: batchSize, longpoll: longpoll)

            var revsByID: [String: [RevisionID]] = [:]
            for row in feed.results {
                revsByID[row.id, default: []].append(contentsOf: row.changes.compactMap { RevisionID($0.rev) })
            }
            var items: [CouchClient.BulkGetItem] = []
            for (id, revs) in try await local.missingRevisions(revsByID) {
                // ローカルのリーフを atts_since に渡し、変わっていない添付は stub で受け取る。
                let attsSince = try await local.leafRevisions(id: id).map(\.description)
                items += revs.map { CouchClient.BulkGetItem(id: id, rev: $0.description, attsSince: attsSince) }
            }

            if !items.isEmpty {
                await onTransfer()
                // 添付を含むと応答が大きくなるため、少しずつ取得する。
                for start in stride(from: 0, to: items.count, by: Self.bulkGetChunkSize) {
                    let chunk = Array(items[start..<min(start + Self.bulkGetChunkSize, items.count)])
                    for doc in try await client.bulkGet(chunk) {
                        let remoteDoc = try RemoteDocument(json: doc)
                        if try await local.merge(id: remoteDoc.id, path: remoteDoc.path, deleted: remoteDoc.deleted,
                                                 body: remoteDoc.body, attachments: remoteDoc.attachments) {
                            written += 1
                        }
                    }
                }
            }

            // 取り込みが確定してからチェックポイントを進める。
            if !feed.results.isEmpty {
                try await checkpoint.save(lastSeq: feed.lastSeq, local: local, client: client)
            }
            since = feed.lastSeq
            if feed.results.count < batchSize { return written }
        }
    }

    /// 追いつくまでローカルの変更を送り、書き込んだ Revision の数を返す。
    ///
    /// - Parameter onTransfer: 実際に文書を送る直前に呼ばれる。
    private func pushBatches(
        _ checkpoint: inout Checkpoint, since: inout Int64, onTransfer: () async -> Void
    ) async throws -> Int {
        var written = 0
        while true {
            try Task.checkCancellation()
            let changes = try await local.changes(since: since, limit: batchSize)
            if changes.results.isEmpty { return written }

            let revsByID = Dictionary(changes.results.map { ($0.id, $0.revs.map(\.description)) },
                                      uniquingKeysWith: { $1 })
            // 添付データを含む文書は大きくなりうるので 1 件ずつ、それ以外はまとめて送る。
            var plainDocs: [JSONValue] = []
            var docsWithData: [JSONValue] = []
            for (id, diff) in try await client.revsDiff(revsByID) {
                for rev in diff.missing.compactMap(RevisionID.init) {
                    // 読み込みの間に更新されてリーフでなくなった rev は、次の push で新しいリーフを送る。
                    guard let doc = try await local.get(id: id, rev: rev) else { continue }
                    let history = try await local.revisionHistory(id: id, rev: rev)

                    // リモートが持っている最も新しい祖先。その generation 以前から変わっていない添付は stub で送れる。
                    let historySet = Set(history)
                    let ancestorGeneration = (diff.possibleAncestors ?? [])
                        .compactMap(RevisionID.init).filter(historySet.contains).map(\.generation).max() ?? 0
                    var data: [String: Data] = [:]
                    for (name, info) in doc.attachments where info.revpos > ancestorGeneration {
                        guard let bytes = try await local.attachment(id: id, name: name, rev: rev) else {
                            throw BocchiDBError.attachmentNotFound(name)
                        }
                        data[name] = bytes
                    }
                    let json = RemoteDocument.json(for: doc, history: history, attachmentData: data)
                    if data.isEmpty { plainDocs.append(json) } else { docsWithData.append(json) }
                }
            }
            if !plainDocs.isEmpty || !docsWithData.isEmpty {
                await onTransfer()
                if !plainDocs.isEmpty { try await client.bulkDocs(plainDocs) }
                for doc in docsWithData { try await client.bulkDocs([doc]) }
                written += plainDocs.count + docsWithData.count
            }

            try await checkpoint.save(lastSeq: .int(changes.lastSeq), local: local, client: client)
            since = changes.lastSeq
            if changes.results.count < batchSize { return written }
        }
    }

    /// pull で 1 回の `_bulk_get` に含める rev の数。
    static let bulkGetChunkSize = 20

    /// ローカル DB の UUID・リモート URL（認証情報を除く）・方向から決まる ID。
    private func replicationID(direction: String) async throws -> String {
        var components = URLComponents(url: remote, resolvingAgainstBaseURL: false)
        components?.user = nil
        components?.password = nil
        let input = "\(try await local.uuid())|\(components?.string ?? remote.absoluteString)|\(direction)"
        return Insecure.MD5.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// ローカルとリモートの `_local/<id>` に保存する同期位置。
private struct Checkpoint {
    let id: String
    /// 再開位置。両側の記録が一致しない場合は `nil`（最初から）。
    let since: JSONValue?
    private var remoteRev: String?
    private let sessionID = UUID().uuidString

    static func load(id: String, local: BocchiDB, client: CouchClient) async throws -> Checkpoint {
        let localDoc = try await local.getLocal(id: id)
        let remoteDoc = try await client.getLocal(id)
        let remoteRev: String? = if case .string(let rev) = remoteDoc?["_rev"] { rev } else { nil }

        var since: JSONValue?
        if let localDoc, let remoteDoc,
           localDoc["session_id"] == remoteDoc["session_id"],
           localDoc["last_seq"] == remoteDoc["last_seq"] {
            since = localDoc["last_seq"]
        }
        return Checkpoint(id: id, since: since, remoteRev: remoteRev)
    }

    private init(id: String, since: JSONValue?, remoteRev: String?) {
        self.id = id
        self.since = since
        self.remoteRev = remoteRev
    }

    /// リモート → ローカルの順に書く。途中で失敗して両者が食い違った場合、次回は最初からやり直す。
    mutating func save(lastSeq: JSONValue, local: BocchiDB, client: CouchClient) async throws {
        let body: [String: JSONValue] = ["session_id": .string(sessionID), "last_seq": lastSeq]
        do {
            remoteRev = try await client.putLocal(id, body: body.merging(revField) { $1 })
        } catch ReplicationError.http(status: 409, _) {
            // 再試行で同じ PUT が二重に届いた場合など。最新の rev を読み直して書き直す。
            remoteRev = if case .string(let rev) = try await client.getLocal(id)?["_rev"] { rev } else { nil }
            remoteRev = try await client.putLocal(id, body: body.merging(revField) { $1 })
        }
        try await local.putLocal(id: id, body: body)
    }

    private var revField: [String: JSONValue] {
        remoteRev.map { ["_rev": .string($0)] } ?? [:]
    }
}

/// CouchDB 側の文書 JSON と、ローカルの表現との変換。
struct RemoteDocument {
    let id: String
    let path: [RevisionID]
    let deleted: Bool
    let body: [String: JSONValue]
    let attachments: [String: IncomingAttachment]

    private static let metaKeys: Set<String> = ["_id", "_rev", "_revisions", "_deleted", "_attachments"]

    /// `_bulk_get?revs=true` が返す文書から作る。
    init(json: [String: JSONValue]) throws {
        guard case .string(let id) = json["_id"],
              case .string(let revString) = json["_rev"],
              let rev = RevisionID(revString)
        else { throw ReplicationError.invalidResponse("document without valid _id/_rev") }

        var path = [rev]
        if case .object(let revisions) = json["_revisions"],
           case .int(let start) = revisions["start"],
           case .array(let ids) = revisions["ids"] {
            path = try ids.enumerated().map { offset, hash in
                guard case .string(let hash) = hash, let rev = RevisionID("\(start - Int64(offset))-\(hash)") else {
                    throw ReplicationError.invalidResponse("invalid _revisions in \(id)")
                }
                return rev
            }
        }
        guard path.first == rev else { throw ReplicationError.invalidResponse("_revisions does not match _rev in \(id)") }

        self.id = id
        self.path = path
        self.deleted = json["_deleted"] == .bool(true)
        // _conflicts などの未対応フィールドは本文に残し、merge の検証でエラーにする。
        self.body = json.filter { !Self.metaKeys.contains($0.key) }

        var attachments: [String: IncomingAttachment] = [:]
        if case .object(let entries) = json["_attachments"] {
            for (name, entry) in entries {
                guard case .object(let fields) = entry,
                      case .string(let contentType) = fields["content_type"],
                      case .int(let revpos) = fields["revpos"]
                else { throw ReplicationError.invalidResponse("invalid attachment \(name) in \(id)") }

                var data: Data?
                if case .string(let base64) = fields["data"] {
                    guard let decoded = Data(base64Encoded: base64) else {
                        throw ReplicationError.invalidResponse("invalid attachment data \(name) in \(id)")
                    }
                    data = decoded
                } else if fields["stub"] != .bool(true) {
                    throw ReplicationError.invalidResponse("attachment \(name) in \(id) has neither data nor stub")
                }
                attachments[name] = IncomingAttachment(contentType: contentType, revpos: Int(revpos), data: data)
            }
        }
        self.attachments = attachments
    }

    /// `_bulk_docs`（new_edits=false）に送る JSON を作る。
    ///
    /// - Parameter attachmentData: データを送る添付。含まれない添付は stub（リモートの祖先と同じ内容）として送る。
    static func json(for doc: Document, history: [RevisionID], attachmentData: [String: Data]) -> JSONValue {
        var json = doc.body
        json["_id"] = .string(doc.id)
        json["_rev"] = .string(doc.rev.description)
        if doc.deleted { json["_deleted"] = true }
        if !doc.attachments.isEmpty {
            json["_attachments"] = .object(Dictionary(uniqueKeysWithValues: doc.attachments.map { name, info in
                var entry: [String: JSONValue] = [
                    "content_type": .string(info.contentType),
                    "revpos": .int(Int64(info.revpos)),
                ]
                if let data = attachmentData[name] {
                    entry["data"] = .string(data.base64EncodedString())
                } else {
                    entry["stub"] = true
                    entry["digest"] = .string(info.digest)
                    entry["length"] = .int(Int64(info.length))
                }
                return (name, JSONValue.object(entry))
            }))
        }
        json["_revisions"] = [
            "start": .int(Int64(doc.rev.generation)),
            "ids": .array(history.map { .string($0.hash) }),
        ]
        return .object(json)
    }
}
