import Foundation
import SQLite3
import Testing
@testable import BocchiDB

@Suite struct OpenModeTests {
    private let directory: URL
    private let url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bocchidb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("db.sqlite")
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 1 文書を書き込んだ DB ファイルを作り、閉じる。
    @discardableResult
    private func makeDatabase() async throws -> RevisionID {
        let db = try BocchiDB(url: url, mode: .create)
        return try await db.put(id: "a", body: ["n": 1])
    }

    private func fileExists(_ suffix: String = "") -> Bool {
        FileManager.default.fileExists(atPath: url.path + suffix)
    }

    // MARK: - ファイルがない場合

    @Test func createMakesNewFile() async throws {
        defer { cleanUp() }
        let db = try BocchiDB(url: url, mode: .create)
        #expect(db.mode == .create)
        #expect(fileExists())
    }

    @Test(arguments: [OpenMode.readWrite, .readOnly])
    func existingOnlyModesDoNotCreateFile(mode: OpenMode) throws {
        defer { cleanUp() }
        #expect(throws: BocchiDBError.fileNotFound) { try BocchiDB(url: url, mode: mode) }
        #expect(!fileExists())
    }

    // MARK: - readWrite

    @Test func readWriteOpensExistingDatabase() async throws {
        defer { cleanUp() }
        let rev = try await makeDatabase()
        let db = try BocchiDB(url: url, mode: .readWrite)
        try await db.put(id: "a", body: ["n": 2], rev: rev)
        #expect(try await db.get(id: "a")?.body == ["n": 2])
    }

    // MARK: - readOnly

    @Test func readOnlyReadsExistingDatabase() async throws {
        defer { cleanUp() }
        try await makeDatabase()
        // -shm はなければ作られる。
        try FileManager.default.removeItem(atPath: url.path + "-shm")

        let db = try BocchiDB(url: url, mode: .readOnly)
        #expect(db.mode == .readOnly)
        #expect(try await db.allDocs().map(\.id) == ["a"])
        #expect(try await db.changes().results.map(\.id) == ["a"])
    }

    /// 読み取り専用の接続は -wal を作れないため、-wal がないと開けない（SQLite の仕様）。
    @Test func readOnlyRequiresWALFile() async throws {
        defer { cleanUp() }
        try await makeDatabase()
        // 正常に閉じたあとなら、-wal の内容は本体に反映済みなので消してよい。
        try FileManager.default.removeItem(atPath: url.path + "-wal")

        #expect(throws: BocchiDBError.walFileMissing) { try BocchiDB(url: url, mode: .readOnly) }
        #expect(!fileExists("-wal"))
        // .readWrite なら -wal を作って開ける。
        #expect(try BocchiDB(url: url, mode: .readWrite).mode == .readWrite)
    }

    @Test func readOnlyRejectsWrites() async throws {
        defer { cleanUp() }
        let rev = try await makeDatabase()
        let before = try Data(contentsOf: url)

        do {
            let db = try BocchiDB(url: url, mode: .readOnly)
            await #expect(throws: BocchiDBError.readOnly) { try await db.put(id: "b", body: [:]) }
            await #expect(throws: BocchiDBError.readOnly) { try await db.remove(id: "a", rev: rev) }
            await #expect(throws: BocchiDBError.readOnly) {
                try await db.bulkDocs([DocumentWrite(id: "b", body: [:])])
            }
            await #expect(throws: BocchiDBError.readOnly) {
                try await db.putAttachment(id: "a", name: "x", contentType: "text/plain", data: Data(), rev: rev)
            }
            await #expect(throws: BocchiDBError.readOnly) {
                try await db.removeAttachment(id: "a", name: "x", rev: rev)
            }
            await #expect(throws: BocchiDBError.readOnly) {
                try await db.merge(id: "b", path: [RevisionID("1-abc")!], deleted: false, body: [:])
            }
            await #expect(throws: BocchiDBError.readOnly) { try await db.putLocal(id: "c", body: [:]) }
            await #expect(throws: BocchiDBError.readOnly) { try await db.removeLocal(id: "c") }
        }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func readOnlySeesWritesFromAnotherConnection() async throws {
        defer { cleanUp() }
        let writer = try BocchiDB(url: url, mode: .create)
        try await writer.put(id: "a", body: [:])

        let reader = try BocchiDB(url: url, mode: .readOnly)
        #expect(try await reader.allDocs().map(\.id) == ["a"])

        try await writer.put(id: "b", body: [:])
        #expect(try await reader.allDocs().map(\.id) == ["a", "b"])
    }

    @Test func replicatorRejectsReadOnlyDatabase() async throws {
        defer { cleanUp() }
        try await makeDatabase()
        let db = try BocchiDB(url: url, mode: .readOnly)
        // 通信の前に拒否するので、つながらない URL でよい。
        let replicator = Replicator(local: db, remote: URL(string: "http://127.0.0.1:9/db")!)
        await #expect(throws: BocchiDBError.readOnly) { try await replicator.pull() }
        await #expect(throws: BocchiDBError.readOnly) { try await replicator.push() }
        await #expect(throws: BocchiDBError.readOnly) { try await replicator.sync() }
        await #expect(throws: BocchiDBError.readOnly) { try await replicator.live() }
    }

    // MARK: - BocchiDB 以外のファイル

    @Test(arguments: [OpenMode.readWrite, .readOnly])
    func rejectsNonBocchiDBFile(mode: OpenMode) throws {
        defer { cleanUp() }
        try executeRaw("CREATE TABLE other (x)")

        #expect(throws: BocchiDBError.unsupportedDatabase("not a BocchiDB database")) {
            try BocchiDB(url: url, mode: mode)
        }
        // スキーマを作っていないこと。
        let tables = try SQLiteConnection(path: url.path, mode: .readOnly)
            .query("SELECT name FROM sqlite_master WHERE type = 'table'")
        #expect(tables == [[.text("other")]])
    }

    @Test(arguments: [OpenMode.readWrite, .readOnly])
    func rejectsUnsupportedSchemaVersion(mode: OpenMode) async throws {
        defer { cleanUp() }
        try await makeDatabase()
        try executeRaw("UPDATE metadata SET value = '999' WHERE key = 'schema_version'")

        #expect(throws: BocchiDBError.unsupportedDatabase("unsupported schema version 999")) {
            try BocchiDB(url: url, mode: mode)
        }
    }

    private func executeRaw(_ sql: String) throws {
        try SQLiteConnection(path: url.path, mode: .create).execute(sql)
    }
}
