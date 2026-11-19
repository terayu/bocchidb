/// `bulkDocs` に渡す 1 件分の書き込み。
public struct DocumentWrite: Sendable {
    public var id: String
    /// 更新・削除する場合は現在のリーフの rev。新規作成なら `nil`。
    public var rev: RevisionID?
    public var deleted: Bool
    public var body: [String: JSONValue]

    public init(id: String, rev: RevisionID? = nil, deleted: Bool = false, body: [String: JSONValue] = [:]) {
        self.id = id
        self.rev = rev
        self.deleted = deleted
        self.body = body
    }
}

/// Changes Feed の 1 件。1 文書につき最新の変更だけが含まれる。
public struct Change: Sendable, Equatable {
    /// ローカル sequence。
    public let seq: Int64
    public let id: String
    /// 勝者 Revision が削除済みか。
    public let deleted: Bool
    /// 全リーフの rev。先頭が勝者。
    public let revs: [RevisionID]
}

public struct ChangesResult: Sendable, Equatable {
    public let results: [Change]
    /// 次回 `since` に渡す値。
    public let lastSeq: Int64
}
