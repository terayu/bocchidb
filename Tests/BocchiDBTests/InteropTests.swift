import Foundation
import Testing
@testable import BocchiDB

/// 実際の CouchDB に対する互換性テスト。
/// 環境変数 `BOCCHIDB_COUCHDB_URL`（例: `http://admin:password@localhost:45984`）がないときはスキップする。
@Suite(.enabled(if: CouchServer.baseURL != nil), .serialized)
struct InteropTests {
    /// 認証失敗のテスト用の、存在しないユーザー名。
    /// CouchDB は同じユーザー名で認証失敗が続くと一時的にロックするため、毎回違う名前にする。
    static var unknownUser: String { "bocchidb_unknown_\(UUID().uuidString.lowercased())" }

    @Test func pushThenPullIntoAnotherDatabase() async throws {
        try await CouchServer.withDatabase { couch in
            let a = try BocchiDB(path: ":memory:")
            let rev1 = try await a.put(id: "inspection-001", body: ["temperature": 25.5])
            try await a.put(id: "inspection-002", body: ["temperature": 26])
            let rev3 = try await a.put(id: "inspection-003", body: [:])
            try await a.remove(id: "inspection-003", rev: rev3)

            #expect(try await couch.replicator(for: a).push().docsWritten == 3)
            #expect(try await couch.getDocument("inspection-001")?["_rev"] == .string(rev1.description))

            let b = try BocchiDB(path: ":memory:")
            #expect(try await couch.replicator(for: b).pull().docsWritten == 3)
            #expect(try await b.allDocs() == a.allDocs())
            #expect(try await b.get(id: "inspection-003") == nil)
        }
    }

    @Test func resumesFromCheckpoint() async throws {
        try await CouchServer.withDatabase { couch in
            let a = try BocchiDB(path: ":memory:")
            try await a.put(id: "x", body: [:])
            let push = couch.replicator(for: a)
            #expect(try await push.push().docsWritten == 1)
            #expect(try await push.push().docsWritten == 0)

            try await a.put(id: "y", body: [:])
            #expect(try await push.push().docsWritten == 1)

            let b = try BocchiDB(path: ":memory:")
            let pull = couch.replicator(for: b)
            #expect(try await pull.pull().docsWritten == 2)
            #expect(try await pull.pull().docsWritten == 0)
        }
    }

    @Test func transfersInMultipleBatches() async throws {
        try await CouchServer.withDatabase { couch in
            let a = try BocchiDB(path: ":memory:")
            for index in 0..<7 {
                try await a.put(id: "doc-\(index)", body: ["index": .int(Int64(index))])
            }
            #expect(try await couch.replicator(for: a, batchSize: 2).push().docsWritten == 7)

            let b = try BocchiDB(path: ":memory:")
            #expect(try await couch.replicator(for: b, batchSize: 3).pull().docsWritten == 7)
            #expect(try await b.allDocs().count == 7)
        }
    }

    /// BocchiDB と PouchDB がオフライン中に同じ文書を更新し、同期後に 3 者の勝者と競合が一致する。
    @Test func agreesWithPouchDBOnConflict() async throws {
        try await CouchServer.withDatabase { couch in
            let db = try BocchiDB(path: ":memory:")
            let replicator = couch.replicator(for: db)
            let rev1 = try await db.put(id: "inspection-001", body: ["temperature": 25.5])
            try await replicator.push()

            // PouchDB 端末が更新して CouchDB に同期。その間 BocchiDB はオフラインで更新する。
            try PouchDevice.run(couch.databaseURLWithCredentials, "update", "inspection-001", #"{"temperature":27}"#)
            try await db.put(id: "inspection-001", body: ["temperature": 26.0], rev: rev1)
            try await replicator.sync()

            let remote = try #require(try await couch.getDocument("inspection-001", conflicts: true))
            let pouch = try PouchDevice.run(couch.databaseURLWithCredentials, "get", "inspection-001")
            let local = try #require(try await db.get(id: "inspection-001"))
            let localConflicts = try await db.conflicts(id: "inspection-001").map { JSONValue.string($0.description) }

            #expect(remote["_rev"] == .string(local.rev.description))
            #expect(pouch["_rev"] == .string(local.rev.description))
            #expect(remote["_conflicts"] == .array(localConflicts))
            #expect(pouch["_conflicts"] == .array(localConflicts))
            #expect(localConflicts.count == 1)

            // BocchiDB で敗者を削除して競合を解消すると、PouchDB 側でも解消される。
            let loser = try #require(try await db.conflicts(id: "inspection-001").first)
            try await db.remove(id: "inspection-001", rev: loser)
            try await replicator.sync()
            let resolved = try PouchDevice.run(couch.databaseURLWithCredentials, "get", "inspection-001")
            #expect(resolved["_conflicts"] == .array([]))
            #expect(resolved["_rev"] == .string(local.rev.description))
        }
    }

    @Test func replicatesWithCookieAuthentication() async throws {
        try await CouchServer.withDatabase { couch in
            guard case .basic(let user, let password) = couch.auth else { return }
            let a = try BocchiDB(path: ":memory:")
            try await a.put(id: "x", body: ["v": 1])
            let replicator = Replicator(local: a, remote: couch.databaseURL,
                                        auth: .session(username: user, password: password))
            #expect(try await replicator.push().docsWritten == 1)

            let b = try BocchiDB(path: ":memory:")
            try await Replicator(local: b, remote: couch.databaseURL,
                                 auth: .session(username: user, password: password)).pull()
            #expect(try await b.get(id: "x")?.body == ["v": 1])
        }
    }

    @Test func cookieAuthenticationRejectsWrongPassword() async throws {
        try await CouchServer.withDatabase { couch in
            let replicator = Replicator(local: try BocchiDB(path: ":memory:"), remote: couch.databaseURL,
                                        auth: .session(username: Self.unknownUser, password: "wrong"))
            await #expect {
                try await replicator.pull()
            } throws: { error in
                if case ReplicationError.http(status: 401, _) = error { true } else { false }
            }
        }
    }

    // MARK: - Live Sync

    /// 2 台の BocchiDB が Live Sync で、互いの変更を待たずに受け取る。
    @Test(.timeLimit(.minutes(1))) func liveSyncDeliversChangesBetweenDevices() async throws {
        try await CouchServer.withDatabase { couch in
            let a = try BocchiDB(path: ":memory:")
            let b = try BocchiDB(path: ":memory:")
            let liveA = Task { try await couch.replicator(for: a).live() }
            let liveB = Task { try await couch.replicator(for: b).live() }

            let seenByB = await b.observeChanges()
            let rev1 = try await a.put(id: "inspection-001", body: ["temperature": 25.5])
            #expect(await nextChange(seenByB, id: "inspection-001")?.revs == [rev1])

            let seenByA = await a.observeChanges()
            let rev2 = try await b.put(id: "inspection-001", body: ["temperature": 26.0], rev: rev1)
            #expect(await nextChange(seenByA, id: "inspection-001")?.revs == [rev2])
            #expect(try await a.get(id: "inspection-001")?.body == ["temperature": 26.0])

            // キャンセルすると、エラーを投げずにすぐ終わる。
            liveA.cancel()
            liveB.cancel()
            try await liveA.value
            try await liveB.value
        }
    }

    @Test(.timeLimit(.minutes(1))) func liveSyncReceivesPouchDBChange() async throws {
        try await CouchServer.withDatabase { couch in
            let db = try BocchiDB(path: ":memory:")
            let live = Task { try await couch.replicator(for: db).live() }

            let stream = await db.observeChanges()
            let pouch = try PouchDevice.run(couch.databaseURLWithCredentials, "update", "from-pouch", #"{"v":1}"#)
            #expect(await nextChange(stream, id: "from-pouch")?.revs.first?.description == pouch["_rev"]?.stringValue)
            #expect(try await db.get(id: "from-pouch")?.body == ["v": 1])

            live.cancel()
            try await live.value
        }
    }

    /// 状態は connecting → idle と進み、転送のたびに active → idle を経て、キャンセルで stopped になる。
    @Test(.timeLimit(.minutes(1))) func liveSyncReportsStatus() async throws {
        try await CouchServer.withDatabase { couch in
            let db = try BocchiDB(path: ":memory:")
            let recorder = StatusRecorder()
            let (statuses, continuation) = AsyncStream.makeStream(of: SyncStatus.self)
            let live = Task {
                try await couch.replicator(for: db).live { status in
                    recorder.record(status)
                    continuation.yield(status)
                }
            }
            var iterator = statuses.makeAsyncIterator()
            func waitFor(_ expected: SyncStatus) async {
                while let status = await iterator.next(), status != expected {}
            }

            await waitFor(.idle)
            try await db.put(id: "local", body: [:])                  // push
            await waitFor(.active)
            await waitFor(.idle)
            try PouchDevice.run(couch.databaseURLWithCredentials, "update", "remote", "{}")  // pull
            await waitFor(.active)
            await waitFor(.idle)

            live.cancel()
            try await live.value
            #expect(recorder.values.first == .connecting)
            #expect(recorder.values.last == .stopped)
            #expect(!recorder.values.contains(.offline))
            #expect(try await db.get(id: "remote") != nil)
        }
    }

    /// 一時的でないエラー（認証失敗）では、再試行し続けずに止まる。
    @Test(.timeLimit(.minutes(1))) func liveSyncStopsOnAuthenticationError() async throws {
        try await CouchServer.withDatabase { couch in
            let replicator = Replicator(local: try BocchiDB(path: ":memory:"), remote: couch.databaseURL,
                                        auth: .session(username: Self.unknownUser, password: "wrong"))
            let statuses = StatusRecorder()
            await #expect {
                try await replicator.live(onStatus: statuses.record)
            } throws: { error in
                if case ReplicationError.http(status: 401, _) = error { true } else { false }
            }
            #expect(statuses.values == [.connecting, .stopped])
        }
    }

    // MARK: - 添付ファイル

    /// CouchDB が gzip で保存する text 系と、そのまま保存する画像の両方を往復させる。
    @Test func pushesAndPullsAttachments() async throws {
        try await CouchServer.withDatabase { couch in
            let photo = Data((0..<2048).map { UInt8($0 % 256) })
            let memo = Data("点検メモ: 異常なし".utf8)
            let a = try BocchiDB(path: ":memory:")
            let rev1 = try await a.putAttachment(id: "inspection-001", name: "photo.jpg", contentType: "image/jpeg", data: photo)
            try await a.putAttachment(id: "inspection-001", name: "memo.txt", contentType: "text/plain", data: memo, rev: rev1)
            try await couch.replicator(for: a).push()

            #expect(try await couch.getAttachment("inspection-001", "photo.jpg") == photo)
            #expect(try await couch.getAttachment("inspection-001", "memo.txt") == memo)

            let b = try BocchiDB(path: ":memory:")
            try await couch.replicator(for: b).pull()
            #expect(try await b.attachment(id: "inspection-001", name: "photo.jpg") == photo)
            #expect(try await b.attachment(id: "inspection-001", name: "memo.txt") == memo)
            #expect(try await b.get(id: "inspection-001")?.attachments == a.get(id: "inspection-001")?.attachments)
        }
    }

    /// 添付付きの文書の本文だけを更新して push すると、添付は stub で送られ、CouchDB 側の添付は保たれる。
    @Test func pushesBodyChangeOfDocumentWithAttachment() async throws {
        try await CouchServer.withDatabase { couch in
            let photo = Data((0..<1024).map { UInt8($0 % 251) })
            let db = try BocchiDB(path: ":memory:")
            let replicator = couch.replicator(for: db)
            let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
            try await replicator.push()
            try await db.put(id: "a", body: ["checked": true], rev: rev1)
            try await replicator.push()

            let remote = try #require(try await couch.getDocument("a"))
            #expect(remote["checked"] == true)
            #expect(try await couch.getAttachment("a", "photo.jpg") == photo)
        }
    }

    /// PouchDB が本文だけを更新した文書を pull すると、添付は stub で届き、ローカルの祖先から復元される。
    @Test func pullsBodyChangeFromPouchDBKeepingAttachment() async throws {
        try await CouchServer.withDatabase { couch in
            let memo = Data("hello".utf8)
            let db = try BocchiDB(path: ":memory:")
            let replicator = couch.replicator(for: db)
            try await db.putAttachment(id: "a", name: "memo.txt", contentType: "text/plain", data: memo)
            try await replicator.push()

            try PouchDevice.run(couch.databaseURLWithCredentials, "update", "a", #"{"checked":true}"#)
            #expect(try await replicator.pull().docsWritten == 1)

            let doc = try #require(try await db.get(id: "a"))
            #expect(doc.rev.generation == 2)
            #expect(doc.body == ["checked": true])
            #expect(doc.attachments["memo.txt"]?.revpos == 1)
            #expect(try await db.attachment(id: "a", name: "memo.txt") == memo)
        }
    }

    /// 他のクライアントが CouchDB に直接付けた添付も取り込める。
    @Test func pullsAttachmentCreatedOnServer() async throws {
        try await CouchServer.withDatabase { couch in
            try await couch.putDocument("with-file", [
                "_attachments": ["a.txt": ["content_type": "text/plain", "data": "aGVsbG8="]],
            ])
            let db = try BocchiDB(path: ":memory:")
            try await couch.replicator(for: db).pull()
            #expect(try await db.attachment(id: "with-file", name: "a.txt") == Data("hello".utf8))
            #expect(try await db.get(id: "with-file")?.attachments["a.txt"]?.digest == "md5-XUFAKrxLKna5cZ2REBfFkg==")
        }
    }

    /// stub を使った転送の前提になる CouchDB の応答（atts_since と possible_ancestors）を確かめる。
    @Test func couchDBReturnsStubsAndPossibleAncestors() async throws {
        try await CouchServer.withDatabase { couch in
            let db = try BocchiDB(path: ":memory:")
            let rev1 = try await db.putAttachment(id: "a", name: "x.bin", contentType: "application/octet-stream",
                                                  data: Data([1, 2, 3]))
            let rev2 = try await db.put(id: "a", body: ["v": 2], rev: rev1)
            try await couch.replicator(for: db).push()

            let client = CouchClient(databaseURL: couch.databaseURL, auth: couch.auth, session: .shared)
            let docs = try await client.bulkGet([.init(id: "a", rev: rev2.description, attsSince: [rev1.description])])
            #expect(docs.first?["_attachments"] == ["x.bin": [
                "content_type": "application/octet-stream", "revpos": 1, "length": 3, "stub": true,
                "digest": .string(AttachmentInfo.digest(of: Data([1, 2, 3]))),
            ]])

            let diff = try await client.revsDiff(["a": ["3-notyet"]])
            #expect(diff["a"]?.possibleAncestors == [rev2.description])
        }
    }
}

// MARK: - テスト用ヘルパー

/// テストごとに一時的なデータベースを作る CouchDB サーバー。
struct CouchServer {
    static let baseURL: URL? = ProcessInfo.processInfo.environment["BOCCHIDB_COUCHDB_URL"].flatMap(URL.init)

    let databaseURL: URL
    let auth: Authentication

    var databaseURLWithCredentials: String {
        var components = URLComponents(url: databaseURL, resolvingAgainstBaseURL: false)!
        if case .basic(let user, let password) = auth {
            components.user = user
            components.password = password
        }
        return components.string!
    }

    static func withDatabase(_ body: (CouchServer) async throws -> Void) async throws {
        var components = URLComponents(url: try #require(baseURL), resolvingAgainstBaseURL: false)!
        let auth: Authentication = if let user = components.user, let password = components.password {
            .basic(username: user, password: password)
        } else { .none }
        components.user = nil
        components.password = nil

        let name = "bocchidb_test_\(UUID().uuidString.lowercased())"
        let server = CouchServer(databaseURL: components.url!.appending(path: name), auth: auth)
        try await server.request("PUT", "")
        do {
            try await body(server)
        } catch {
            _ = try? await server.request("DELETE", "")
            throw error
        }
        _ = try? await server.request("DELETE", "")
    }

    func replicator(for db: BocchiDB, batchSize: Int = 100) -> Replicator {
        Replicator(local: db, remote: databaseURL, auth: auth, batchSize: batchSize)
    }

    func getDocument(_ id: String, conflicts: Bool = false) async throws -> [String: JSONValue]? {
        let (data, status) = try await request("GET", id + (conflicts ? "?conflicts=true" : ""))
        guard status == 200 else { return nil }
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    func getAttachment(_ id: String, _ name: String) async throws -> Data? {
        let (data, status) = try await request("GET", "\(id)/\(name)")
        return status == 200 ? data : nil
    }

    func putDocument(_ id: String, _ body: [String: JSONValue]) async throws {
        let (_, status) = try await request("PUT", id, body: try JSONEncoder().encode(body))
        #expect(status == 201)
    }

    func bulkDocs(_ docs: [[String: JSONValue]]) async throws {
        let (_, status) = try await request("POST", "_bulk_docs", body: try JSONEncoder().encode(["docs": docs]))
        #expect(status == 201)
    }

    func createIndex(fields: [String]) async throws {
        let (_, status) = try await request("POST", "_index", body: try JSONEncoder().encode(
            ["index": ["fields": JSONValue.array(fields.map(JSONValue.string))]] as JSONValue))
        #expect(status == 200)
    }

    func createIndex(fields: [String], ddoc: String, name: String) async throws {
        let (_, status) = try await request("POST", "_index", body: try JSONEncoder().encode(
            ["index": ["fields": .array(fields.map(JSONValue.string))], "ddoc": .string(ddoc), "name": .string(name)] as JSONValue))
        #expect(status == 200)
    }

    func deleteIndex(ddoc: String, name: String) async throws {
        let (_, status) = try await request("DELETE", "_index/\(ddoc)/json/\(name)")
        #expect(status == 200)
    }

    /// `_find` の結果の文書。エラーなら CouchDB の応答をそのまま投げる。
    func find(_ query: Data) async throws -> [[String: JSONValue]] {
        let (data, status) = try await request("POST", "_find", body: query)
        guard status == 200 else {
            throw ReplicationError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        struct Response: Decodable { let docs: [[String: JSONValue]] }
        return try JSONDecoder().decode(Response.self, from: data).docs
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: Data? = nil) async throws -> (Data, Int) {
        let url = URL(string: databaseURL.absoluteString + (path.isEmpty ? "" : "/" + path))!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if case .basic(let user, let password) = auth {
            request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(),
                             forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// `interop/pouch-device.mjs` を実行する。
enum PouchDevice {
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "interop/pouch-device.mjs")

    @discardableResult
    static func run(_ arguments: String...) throws -> [String: JSONValue] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", script.path] + arguments
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try JSONDecoder().decode([String: JSONValue].self, from: data)
    }
}

private extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { s } else { nil } }
}
