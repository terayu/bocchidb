/// `BocchiDB` でファイルを開くときの方法。
public enum OpenMode: Sendable, Equatable {
    /// 読み書きできる状態で開く。ファイルがなければ新しく作る。
    case create
    /// 既存の BocchiDB ファイルを読み書きできる状態で開く。ファイルがなければ `BocchiDBError.fileNotFound`。
    case readWrite
    /// 既存の BocchiDB ファイルを読み取り専用で開く。DB 本体と `-wal` ファイルには書き込まない。
    ///
    /// - 書き込み系の API と `Replicator` は `BocchiDBError.readOnly` を投げる。
    /// - 他のプロセスが同じファイルに書き込んでいる間も、一貫した内容を読める。
    /// - `observeChanges()` は自分の書き込みだけを通知するため、このモードでは何も流れない。
    /// - ファイルがなければ `BocchiDBError.fileNotFound`。
    /// - `-wal` ファイルが隣にないと開けない（`BocchiDBError.walFileMissing`）。`-shm` ファイルはなければ作られるため、
    ///   同じフォルダへの書き込み権限が必要になる。
    case readOnly
}
