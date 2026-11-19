import Foundation
import Testing
@testable import BocchiDB

@Suite struct SQLiteConnectionTests {
    @Test func opensInMemoryDatabase() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(try db.scalarText("SELECT 'ok'") == "ok")
    }

    /// 設計で前提にしている OS 同梱 SQLite の機能（JSON 関数、WAL）が使えることを確認する。
    @Test func supportsJSONFunctions() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(try db.scalarText(#"SELECT json_extract('{"a":{"b":42}}', '$.a.b')"#) == "42")
    }

    @Test func enablesWALOnFileDatabase() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bocchidb-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let db = try SQLiteConnection(path: path)
        #expect(try db.scalarText("PRAGMA journal_mode=WAL") == "wal")
    }

    @Test func bindsAndReadsAllValueTypes() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t (a, b, c, d)")
        let row: [SQLiteValue] = [.null, .integer(42), .text("温度"), .blob(Data([0, 1, 2]))]
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?)", row)
        #expect(try db.query("SELECT a, b, c, d FROM t") == [row])
    }

    @Test func rollsBackFailedTransaction() throws {
        let db = try SQLiteConnection(path: ":memory:")
        try db.execute("CREATE TABLE t (a INTEGER)")
        #expect(throws: SQLiteError.self) {
            try db.transaction {
                try db.run("INSERT INTO t VALUES (1)")
                try db.run("NOT SQL")
            }
        }
        #expect(try db.query("SELECT count(*) FROM t") == [[.integer(0)]])
    }

    @Test func throwsOnInvalidSQL() throws {
        let db = try SQLiteConnection(path: ":memory:")
        #expect(throws: SQLiteError.self) { try db.execute("NOT SQL") }
    }
}
