/// `"<generation>-<hash>"` 形式の Revision ID。
public struct RevisionID: Sendable, Hashable {
    /// 1 から始まる世代番号。
    public let generation: Int
    /// Revision を識別するハッシュ部分。
    public let hash: String

    /// 文字列から生成する。形式が不正な場合は `nil`。
    public init?(_ string: String) {
        guard let dash = string.firstIndex(of: "-") else { return nil }
        let generationPart = string[..<dash]
        let hashPart = string[string.index(after: dash)...]

        guard !generationPart.isEmpty,
              generationPart.allSatisfy({ $0.isASCII && $0.isNumber }),
              let generation = Int(generationPart),
              generation >= 1,
              !hashPart.isEmpty
        else { return nil }

        self.generation = generation
        self.hash = String(hashPart)
    }
}

extension RevisionID: CustomStringConvertible {
    public var description: String { "\(generation)-\(hash)" }
}

extension RevisionID: Comparable {
    /// generation を数値で比較し、同じならハッシュをバイト列として比較する（CouchDB と同じ順序）。
    public static func < (lhs: RevisionID, rhs: RevisionID) -> Bool {
        if lhs.generation != rhs.generation {
            return lhs.generation < rhs.generation
        }
        return lhs.hash.utf8.lexicographicallyPrecedes(rhs.hash.utf8)
    }
}

extension RevisionID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let rev = RevisionID(string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid revision ID: \(string)")
        }
        self = rev
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Revision Tree のリーフ。
struct LeafRevision: Sendable, Hashable {
    let rev: RevisionID
    let deleted: Bool
}

/// リーフの中から勝者 Revision を選ぶ（CouchDB と同じ規則）。
///
/// 1. 削除されていないものを優先
/// 2. generation が大きいもの
/// 3. ハッシュをバイト列として比較して大きいもの
func winningRevision(of leaves: some Sequence<LeafRevision>) -> LeafRevision? {
    leaves.max { lhs, rhs in
        if lhs.deleted != rhs.deleted {
            return lhs.deleted  // 削除済みのほうが小さい
        }
        return lhs.rev < rhs.rev
    }
}
