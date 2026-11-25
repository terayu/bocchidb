/// 保存されている文書の 1 Revision。
public struct Document: Sendable, Equatable {
    public let id: String
    public let rev: RevisionID
    public let deleted: Bool
    /// `_id` や `_rev` などの予約フィールドを含まない本文。
    public let body: JSONObject
    /// 添付ファイルの情報（名前 → 情報）。
    public internal(set) var attachments: [String: AttachmentInfo] = [:]
}
