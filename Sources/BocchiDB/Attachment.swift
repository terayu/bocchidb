import CryptoKit
import Foundation

/// 文書に付いている添付ファイルの情報（データ本体は `BocchiDB.attachment(id:name:rev:)` で取得する）。
public struct AttachmentInfo: Sendable, Hashable {
    public let contentType: String
    /// データの MD5（`"md5-<base64>"`）。ローカルで元のデータから計算した値。
    ///
    /// CouchDB は text 系などを gzip 圧縮して保存し、圧縮後のデータから digest を計算するため、
    /// CouchDB 側の `digest` とは一致しない場合がある。
    public let digest: String
    /// データのバイト数。
    public let length: Int
    /// この添付が最後に変更された Revision の generation。
    public let revpos: Int

    static func digest(of data: Data) -> String {
        "md5-" + Data(Insecure.MD5.hash(data: data)).base64EncodedString()
    }
}

/// 同期で取り込む添付。`data` が `nil` なら stub（祖先の Revision と同じ内容）。
struct IncomingAttachment: Sendable {
    let contentType: String
    let revpos: Int
    let data: Data?
}
