import Foundation
import Testing
@testable import BocchiDB

@Suite struct CompactTests {
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

    private func size(_ suffix: String = "") -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path + suffix)
        return (attributes?[.size] as? Int) ?? 0
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    @Test func compactShrinksFileAfterDeletes() async throws {
        defer { cleanUp() }
        let db = try BocchiDB(url: url)
        let kept = try await db.put(id: "kept", body: ["n": 1])
        var revs: [RevisionID] = []
        for i in 0..<20 {
            revs.append(try await db.putAttachment(id: "doc-\(i)", name: "photo.jpg", contentType: "image/jpeg",
                                                   data: randomData(256 * 1024)))
        }
        for (i, rev) in revs.enumerated() {
            try await db.remove(id: "doc-\(i)", rev: rev)
        }
        let before = size() + size("-wal")
        #expect(before > 5 * 1024 * 1024)

        try await db.compact()

        #expect(size() < 1024 * 1024)
        #expect(size("-wal") == 0)
        #expect(try await db.get(id: "kept")?.rev == kept)
        // 削除の記録は残り、同期で相手に伝えられる。
        #expect(try await db.get(id: "doc-0") == nil)
        #expect(try await db.changes(since: 0).results.contains { $0.id == "doc-0" && $0.deleted })
    }

    @Test func compactKeepsDataAcrossReopen() async throws {
        defer { cleanUp() }
        do {
            let db = try BocchiDB(url: url)
            let rev = try await db.putAttachment(id: "a", name: "memo.txt", contentType: "text/plain",
                                                 data: Data("hello".utf8))
            try await db.put(id: "b", body: ["n": 2])
            try await db.remove(id: "b", rev: try #require(try await db.get(id: "b")).rev)
            try await db.compact()
            #expect(try await db.get(id: "a")?.rev == rev)
        }
        let reopened = try BocchiDB(url: url, mode: .readWrite)
        #expect(try await reopened.attachment(id: "a", name: "memo.txt") == Data("hello".utf8))
        #expect(try await reopened.get(id: "b") == nil)
    }

    @Test func compactIsRejectedInReadOnly() async throws {
        defer { cleanUp() }
        try await BocchiDB(url: url).put(id: "a", body: [:])
        let db = try BocchiDB(url: url, mode: .readOnly)
        await #expect(throws: BocchiDBError.readOnly) { try await db.compact() }
    }

    @Test func walShrinksAfterLargeWrite() async throws {
        defer { cleanUp() }
        let db = try BocchiDB(url: url)

        try await db.putAttachment(id: "big", name: "video.mov", contentType: "video/quicktime",
                                   data: randomData(24 * 1024 * 1024))
        #expect(size("-wal") > 16 * 1024 * 1024)

        // Apple の SQLite は journal_size_limit の既定が 32KB なので、
        // チェックポイントが済んだ後の次の書き込みで -wal は小さく戻る。
        try await db.put(id: "a", body: [:])
        try await db.put(id: "b", body: [:])
        #expect(size("-wal") < 1024 * 1024)
    }
}
