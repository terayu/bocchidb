/// BocchiDB が返すエラー。
public enum BocchiDBError: Error, Equatable, Sendable {
    /// 指定した rev が最新のリーフではない、または既存文書に rev なしで書き込もうとした。
    case conflict
    /// 文書 ID が不正（空、または `_design/` 以外の `_` 始まり）。
    case invalidDocumentID(String)
    /// 本文が不正（`_` で始まるキーを含むなど）。
    case invalidBody(String)
    /// Revision の履歴が不正（空、または generation が連続していない）。
    case invalidRevisionHistory
    /// 指定した名前の添付ファイルがない。
    case attachmentNotFound(String)
    /// 添付ファイルが不正（名前が空または `_` 始まり、または同期で受け取った stub に対応するデータがない）。
    case invalidAttachment(String)
    /// 読み取り専用（`OpenMode.readOnly`）で開いた DB に書き込もうとした。
    case readOnly
    /// 開いたファイルが SQLite や BocchiDB のデータベースではない、または対応していないスキーマのバージョン。
    case unsupportedDatabase(String)
    /// `.readWrite` または `.readOnly` で開こうとしたファイルが存在しない。
    case fileNotFound
    /// `.readOnly` で開こうとしたが、隣に `-wal` ファイルがない（読み取り専用の接続では作れない）。
    case walFileMissing
    /// ファイルを読めない、書き込みモードでファイルに書けない、または `-wal` や `-shm` を作る必要があるのにフォルダに書き込めない。
    case permissionDenied
}
