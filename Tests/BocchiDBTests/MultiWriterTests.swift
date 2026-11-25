import Foundation
import Testing
@testable import BocchiDB

/// 同じファイルを複数のインスタンスから書き込む場合。
@Suite struct MultiWriterTests {
    private let directory: URL
    private let path: String

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("bocchidb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("db.sqlite").path
    }

    private func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// ロックが空くのを待つので、並行して書き込んでもエラーにならない。索引の更新も両方から行われる。
    @Test func twoInstancesCanWriteConcurrently() async throws {
        defer { cleanUp() }
        let first = try BocchiDB(path: path)
        let second = try BocchiDB(path: path, mode: .readWrite)
        try await first.createIndex(fields: ["n"])

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (name, db) in [("a", first), ("b", second)] {
                group.addTask {
                    for i in 0..<300 {
                        try await db.put(id: "\(name)-\(i)", body: ["n": .int(Int64(i))])
                        if i % 50 == 0 { _ = try await db.find(FindQuery(selector: ["n": ["$lt": 10]])) }
                    }
                }
            }
            try await group.waitForAll()
        }

        for db in [first, second] {
            #expect(try await db.allDocs().count == 600)
            #expect(try await db.find(FindQuery(selector: ["n": ["$lt": 10]], limit: 1000)).count == 20)
            #expect(await db.lastFindIndex != nil)
        }
    }

    @Test func busyAfterTimeout() throws {
        defer { cleanUp() }
        let holder = try SQLiteConnection(path: path)
        try holder.execute("PRAGMA journal_mode = WAL; CREATE TABLE t (a)")
        let waiter = try SQLiteConnection(path: path, busyTimeout: 50)

        try holder.execute("BEGIN IMMEDIATE")
        #expect(throws: BocchiDBError.busy) { try waiter.run("INSERT INTO t VALUES (1)") }
        #expect(throws: BocchiDBError.busy) { try waiter.transaction { } }
        try holder.execute("COMMIT")
        try waiter.run("INSERT INTO t VALUES (1)")
    }
}
