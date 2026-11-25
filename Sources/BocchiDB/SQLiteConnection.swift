import Foundation
import SQLite3

/// SQLite に渡す・SQLite から受け取る値。
enum SQLiteValue: Equatable {
    case null
    case integer(Int64)
    case text(String)
    case blob(Data)

    var integer: Int64? { if case .integer(let v) = self { v } else { nil } }
    var text: String? { if case .text(let v) = self { v } else { nil } }
    var blob: Data? { if case .blob(let v) = self { v } else { nil } }
}

/// OS 同梱の SQLite を直接扱う内部ラッパー。
final class SQLiteConnection {
    private let handle: OpaquePointer

    /// `path` に ":memory:" を渡すとインメモリ DB を開く。
    ///
    /// - Parameter busyTimeout: 別の接続が書き込み中のとき、ロックが空くのを待つ時間（ミリ秒）。
    ///   待っても取れなければ `BocchiDBError.busy` になる。
    init(path: String, mode: OpenMode = .create, busyTimeout: Int32 = 5000) throws {
        var db: OpaquePointer?
        let access = switch mode {
        case .create: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        case .readWrite: SQLITE_OPEN_READWRITE
        case .readOnly: SQLITE_OPEN_READONLY
        }
        let flags = access | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message)
        }
        sqlite3_busy_timeout(db, busyTimeout)
        handle = db
    }

    deinit {
        sqlite3_close(handle)
    }

    /// 結果を返さない SQL を実行する（複数文を含んでよい、パラメータなし）。
    func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard rc == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            if rc & 0xFF == SQLITE_BUSY { throw BocchiDBError.busy }
            throw SQLiteError(code: rc, message: message)
        }
    }

    /// 1 行 1 列の値を文字列として返す SQL を実行する。
    func scalarText(_ sql: String) throws -> String? {
        switch try query(sql).first?.first {
        case .text(let v): v
        case .integer(let v): String(v)
        default: nil
        }
    }

    /// パラメータ付きの 1 文を実行する。
    func run(_ sql: String, _ arguments: [SQLiteValue] = []) throws {
        _ = try query(sql, arguments)
    }

    /// パラメータ付きの 1 文を実行し、全行を返す。
    func query(_ sql: String, _ arguments: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        var statement: OpaquePointer?
        try check(sqlite3_prepare_v2(handle, sql, -1, &statement, nil))
        defer { sqlite3_finalize(statement) }

        for (offset, argument) in arguments.enumerated() {
            try bind(argument, at: Int32(offset + 1), to: statement)
        }

        var rows: [[SQLiteValue]] = []
        while true {
            let rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { return rows }
            guard rc == SQLITE_ROW else { try check(rc); return rows }
            rows.append((0..<sqlite3_column_count(statement)).map { column(at: $0, of: statement) })
        }
    }

    /// `body` を 1 つのトランザクションで実行する。エラー時はロールバックする。
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Private

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ value: SQLiteValue, at index: Int32, to statement: OpaquePointer?) throws {
        let rc: Int32 = switch value {
        case .null:
            sqlite3_bind_null(statement, index)
        case .integer(let v):
            sqlite3_bind_int64(statement, index, v)
        case .text(let v):
            sqlite3_bind_text(statement, index, v, -1, Self.transient)
        case .blob(let v):
            v.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
        }
        try check(rc)
    }

    private func column(at index: Int32, of statement: OpaquePointer?) -> SQLiteValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_TEXT:
            return .text(String(cString: sqlite3_column_text(statement, index)))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default:
            return .null
        }
    }

    private func check(_ rc: Int32) throws {
        guard rc == SQLITE_OK else {
            if rc & 0xFF == SQLITE_BUSY { throw BocchiDBError.busy }
            throw SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
    }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String

    var description: String { "SQLite error \(code): \(message)" }
}
