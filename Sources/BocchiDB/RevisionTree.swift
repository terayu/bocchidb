/// 1 文書分の Revision Tree（メモリ上の値型）。
///
/// 本文は持たず、Revision 同士の親子関係と削除フラグだけを扱う。
struct RevisionTree: Sendable {
    struct Node: Sendable, Equatable {
        var parent: RevisionID?
        var deleted: Bool
    }

    private(set) var nodes: [RevisionID: Node] = [:]

    init() {}

    init(nodes: [RevisionID: Node]) {
        self.nodes = nodes
    }

    func contains(_ rev: RevisionID) -> Bool { nodes[rev] != nil }
    func parent(of rev: RevisionID) -> RevisionID? { nodes[rev]?.parent }
    func isDeleted(_ rev: RevisionID) -> Bool { nodes[rev]?.deleted ?? false }

    /// 子を持たない Revision の一覧（generation の降順）。
    var leaves: [LeafRevision] {
        let parents = Set(nodes.values.compactMap(\.parent))
        return nodes
            .filter { !parents.contains($0.key) }
            .map { LeafRevision(rev: $0.key, deleted: $0.value.deleted) }
            .sorted { $0.rev > $1.rev }
    }

    func isLeaf(_ rev: RevisionID) -> Bool {
        contains(rev) && !nodes.values.contains { $0.parent == rev }
    }

    /// 履歴付きの Revision を木に取り込む（CouchDB の `new_edits=false` に相当）。
    ///
    /// - Parameters:
    ///   - path: 取り込む Revision とその祖先。新しい順で、generation が 1 ずつ減ること。
    ///   - deleted: `path[0]` が削除 Revision かどうか。
    /// - Returns: 新たに追加した Revision（古い順）。すでに `path[0]` があれば空。
    @discardableResult
    mutating func merge(path: [RevisionID], deleted: Bool) throws(BocchiDBError) -> [RevisionID] {
        guard let newest = path.first,
              path.enumerated().allSatisfy({ $0.element.generation == newest.generation - $0.offset })
        else { throw .invalidRevisionHistory }

        if contains(newest) { return [] }

        // 木の中にある最も新しい祖先を接続点にする。なければ path の最古が新しいルートになる。
        let attachIndex = path.indices.dropFirst().first(where: { contains(path[$0]) }) ?? path.count

        var inserted: [RevisionID] = []
        for index in (0..<attachIndex).reversed() {
            let parent = index + 1 < path.count ? path[index + 1] : nil
            nodes[path[index]] = Node(parent: parent, deleted: index == 0 && deleted)
            inserted.append(path[index])
        }
        return inserted
    }

    /// 各リーフから `limit` 世代より古い祖先を取り除く（CouchDB と同じ方式）。
    ///
    /// CouchDB は、リーフごとの履歴を `limit` 世代で切ってから木を組み直す。そのため、別のリーフのために残った祖先でも、
    /// あるリーフから見て `limit` を超える位置にあれば、そのリーフ側の枝とのつながりは切れる。
    /// これにより、取り込む順番によらず同じ木になり、各リーフの履歴は必ず `limit` 以内に収まる。
    ///
    /// - Returns: 削除した Revision と、親とのつながりが切れて新しくルートになった Revision。
    mutating func stem(limit: Int) -> (removed: [RevisionID], newRoots: [RevisionID]) {
        // 各 Revision から、最も近い子孫リーフまでの距離（リーフ自身は 0）。
        var distance: [RevisionID: Int] = [:]
        for leaf in leaves {
            var current: RevisionID? = leaf.rev
            var depth = 0
            while let rev = current, depth < limit {
                if let known = distance[rev], known <= depth { break }  // より近いリーフからたどり済み
                distance[rev] = depth
                current = nodes[rev]?.parent
                depth += 1
            }
        }

        let removed = nodes.keys.filter { distance[$0] == nil }
        for rev in removed { nodes[rev] = nil }

        // 親が、この Revision 経由で limit 以内にあるときだけつながりを残す。
        var newRoots: [RevisionID] = []
        for (rev, node) in nodes where node.parent != nil && distance[rev]! + 1 >= limit {
            nodes[rev]?.parent = nil
            newRoots.append(rev)
        }
        return (removed, newRoots)
    }
}
