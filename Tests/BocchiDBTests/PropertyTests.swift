import Foundation
import Testing
@testable import BocchiDB

/// シードから再現できる乱数（SplitMix64）。失敗したテストはメッセージのシードで再現できる。
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 複数の端末で編集されたような、ランダムな Revision の木を作る。
private struct RandomHistory {
    /// 各 Revision の、ルートからの完全な履歴（新しい順）と削除フラグ。
    var paths: [(path: [RevisionID], deleted: Bool)] = []

    init(using random: inout SeededRandom, size: Int) {
        var nodes: [(rev: RevisionID, parent: Int?, deleted: Bool)] = []
        for index in 0..<size {
            // 2 割は新しいルート（共通の祖先がない履歴）、それ以外は既存の Revision の子。
            let parent: Int? = nodes.isEmpty || Int.random(in: 0..<10, using: &random) < 2
                ? nil : Int.random(in: 0..<nodes.count, using: &random)
            let generation = parent.map { nodes[$0].rev.generation + 1 } ?? 1
            let hash = String(format: "%04x%04x", index, Int.random(in: 0..<0xFFFF, using: &random))
            let deleted = Int.random(in: 0..<10, using: &random) < 2
            nodes.append((RevisionID("\(generation)-\(hash)")!, parent, deleted))
        }
        for index in nodes.indices {
            var path: [RevisionID] = []
            var current: Int? = index
            while let node = current {
                path.append(nodes[node].rev)
                current = nodes[node].parent
            }
            paths.append((path, nodes[index].deleted))
        }
    }
}

@Suite struct RevisionTreePropertyTests {
    private static let seeds: [UInt64] = Array(0..<300)

    /// 比較に使う木の形：親子関係と、リーフの削除フラグ。
    ///
    /// 途中の Revision の削除フラグは、取り込む順番によって変わりうる（子の履歴として先に届くと不明なため false）。
    /// 勝者の判定にはリーフの削除フラグしか使わないので、比較から外す（CouchDB も同じ）。
    private func shape(_ tree: RevisionTree) -> [RevisionID: String] {
        let leaves = Dictionary(uniqueKeysWithValues: tree.leaves.map { ($0.rev, $0.deleted) })
        return tree.nodes.mapValues { node in
            "\(node.parent?.description ?? "root")"
        }.merging(leaves.mapValues { "leaf deleted=\($0)" }) { parent, leaf in "\(parent) \(leaf)" }
    }

    /// 同じ履歴の集合は、どの順番で取り込んでも同じ結果になる。
    ///
    /// - ステミングなし：木の形まで一致する。
    /// - ステミングあり：リーフ（とその削除フラグ）と勝者が一致する。木の内部の形は順番で変わりうる。
    ///   ステミング済みの木より古い履歴は、後から届いても木の上に付け足されないため（CouchDB も同じ）。
    ///   また、互いに祖先関係にないリーフだけを取り込む（レプリケーションで届くのは各ブランチのリーフ）。
    ///   ステミングで消えた祖先がリーフとして後から届くと、子孫とつながらない偽の競合になる。
    ///   これは CouchDB でも同じで、前回の同期から revsLimit 回を超えて編集した場合に起こりうる。
    @Test(arguments: [nil, 3, 1] as [Int?])
    func mergeOrderDoesNotMatter(revsLimit: Int?) throws {
        for seed in Self.seeds {
            var random = SeededRandom(seed: seed)
            var history = RandomHistory(using: &random, size: Int.random(in: 1...25, using: &random))
            if revsLimit != nil {
                let ancestors = Set(history.paths.flatMap { $0.path.dropFirst() })
                history.paths.removeAll { ancestors.contains($0.path[0]) }
            }

            func build(_ order: [(path: [RevisionID], deleted: Bool)]) throws -> RevisionTree {
                var tree = RevisionTree()
                for entry in order {
                    try tree.merge(path: entry.path, deleted: entry.deleted)
                    if let revsLimit { _ = tree.stem(limit: revsLimit) }
                }
                return tree
            }

            let expected = try build(history.paths)
            for _ in 0..<5 {
                let actual = try build(history.paths.shuffled(using: &random))
                let message: Comment = "seed \(seed), revsLimit \(String(describing: revsLimit))"
                if revsLimit == nil {
                    #expect(shape(actual) == shape(expected), message)
                } else {
                    #expect(Set(actual.leaves) == Set(expected.leaves), message)
                }
                #expect(winningRevision(of: actual.leaves) == winningRevision(of: expected.leaves), "seed \(seed)")
            }
        }
    }

    /// 取り込みとステミングを繰り返しても、木の不変条件が保たれる。
    @Test func invariantsHoldAfterRandomMergesAndStemming() throws {
        for seed in Self.seeds {
            var random = SeededRandom(seed: seed)
            let history = RandomHistory(using: &random, size: Int.random(in: 1...25, using: &random))
            let limit = Int.random(in: 1...4, using: &random)
            var tree = RevisionTree()
            let fullPaths = Dictionary(uniqueKeysWithValues: history.paths.map { ($0.path[0], $0.path) })

            for entry in history.paths.shuffled(using: &random) {
                // 送り手が古い履歴を持っていない場合を想定し、履歴を途中で切ることもある。
                let length = Int.random(in: 1...entry.path.count, using: &random)
                let leavesBefore = Set(tree.leaves.map(\.rev))
                try tree.merge(path: Array(entry.path.prefix(length)), deleted: entry.deleted)
                _ = tree.stem(limit: limit)

                let leaves = Set(tree.leaves.map(\.rev))
                let message: Comment = "seed \(seed)"
                // 取り込んだ Revision は必ず残る。
                #expect(tree.contains(entry.path[0]), message)
                // リーフが消えてよいのは、子孫が付いた（その後ステミングで消えた）場合だけ。
                for rev in leavesBefore where !leaves.contains(rev) {
                    let hasDescendantLeaf = leaves.contains { fullPaths[$0]?.dropFirst().contains(rev) == true }
                    #expect(hasDescendantLeaf, message)
                }
                for (rev, node) in tree.nodes {
                    // 親は木の中にあり、generation が 1 つ小さい。
                    if let parent = node.parent {
                        #expect(tree.contains(parent), message)
                        #expect(parent.generation == rev.generation - 1, message)
                    }
                }
                // どの Revision も、いずれかのリーフから limit 世代以内にある（それより古いものは残らない）。
                var withinLimit = Set<RevisionID>()
                for leaf in leaves {
                    var current: RevisionID? = leaf
                    for _ in 0..<limit {
                        guard let rev = current else { break }
                        withinLimit.insert(rev)
                        current = tree.parent(of: rev)
                    }
                }
                #expect(Set(tree.nodes.keys) == withinLimit, message)
                // 勝者はリーフで、どのリーフにも負けない。
                if let winner = winningRevision(of: tree.leaves) {
                    #expect(leaves.contains(winner.rev), message)
                    for leaf in tree.leaves {
                        if winner.deleted { #expect(leaf.deleted, message) }
                        if leaf.deleted == winner.deleted { #expect(leaf.rev <= winner.rev, message) }
                    }
                }
            }
        }
    }
}

@Suite struct ReplicaConvergencePropertyTests {
    /// 2 台の DB がそれぞれランダムに編集した後、互いに全履歴を取り込むと同じ状態になる。
    @Test(arguments: [1000, 2])
    func replicasConvergeAfterExchange(revsLimit: Int) async throws {
        for seed in UInt64(0)..<60 {
            var random = SeededRandom(seed: seed)
            let a = try BocchiDB(path: ":memory:", revsLimit: revsLimit)
            let b = try BocchiDB(path: ":memory:", revsLimit: revsLimit)

            // 共通の出発点を作ってから、それぞれがオフラインで編集する。
            for _ in 0..<3 { try await Self.randomEdit(a, using: &random) }
            try await Self.copyAll(from: a, to: b)
            for _ in 0..<Int.random(in: 1...12, using: &random) {
                try await Self.randomEdit(Bool.random(using: &random) ? a : b, using: &random)
            }

            try await Self.copyAll(from: a, to: b)
            try await Self.copyAll(from: b, to: a)

            let message: Comment = "seed \(seed), revsLimit \(revsLimit)"
            #expect(try await Self.snapshot(a) == Self.snapshot(b), message)
        }
    }

    private static let ids = ["doc-1", "doc-2", "doc-3"]

    /// 作成・更新・削除・添付の追加と削除を、現在のリーフのどれかに対してランダムに行う。
    private static func randomEdit(_ db: BocchiDB, using random: inout SeededRandom) async throws {
        let id = ids.randomElement(using: &random)!
        let leaves = try await db.leafRevisions(id: id)
        let parent = leaves.randomElement(using: &random)
        let value = JSONValue.int(Int64(Int.random(in: 0..<1000, using: &random)))

        do {
            switch Int.random(in: 0..<10, using: &random) {
            case 0..<5:
                try await db.put(id: id, body: ["v": value], rev: parent)
            case 5..<7:
                if let parent { try await db.remove(id: id, rev: parent) }
            case 7..<9:
                let data = Data("data-\(value)".utf8)
                try await db.putAttachment(id: id, name: "file-\(Int.random(in: 0..<2, using: &random))",
                                           contentType: "text/plain", data: data, rev: parent)
            default:
                if let parent, let name = try await db.get(id: id, rev: parent)?.attachments.keys.sorted().first {
                    try await db.removeAttachment(id: id, name: name, rev: parent)
                }
            }
        } catch BocchiDBError.conflict {
            // rev なしで既存の文書に書いた場合など。ランダム操作では起こりうる。
        }
    }

    /// `source` の全リーフを、履歴・本文・添付付きで `target` に取り込む（レプリケーションと同じ操作）。
    private static func copyAll(from source: BocchiDB, to target: BocchiDB) async throws {
        for change in try await source.changes().results {
            for rev in change.revs {
                guard let doc = try await source.get(id: change.id, rev: rev) else { continue }
                let history = try await source.revisionHistory(id: change.id, rev: rev)
                var attachments: [String: IncomingAttachment] = [:]
                for (name, info) in doc.attachments {
                    attachments[name] = IncomingAttachment(
                        contentType: info.contentType, revpos: info.revpos,
                        data: try await source.attachment(id: change.id, name: name, rev: rev))
                }
                try await target.merge(id: change.id, path: history, deleted: doc.deleted, body: doc.body,
                                       attachments: attachments)
            }
        }
    }

    private struct DocumentSnapshot: Equatable {
        let winner: Document?
        let leaves: Set<RevisionID>
        let conflicts: [RevisionID]
        let attachmentData: [String: Data]
    }

    private static func snapshot(_ db: BocchiDB) async throws -> [String: DocumentSnapshot] {
        var result: [String: DocumentSnapshot] = [:]
        for id in ids {
            let winner = try await db.get(id: id)
            var data: [String: Data] = [:]
            for name in winner?.attachments.keys ?? [:].keys {
                data[name] = try await db.attachment(id: id, name: name)
            }
            result[id] = DocumentSnapshot(
                winner: winner, leaves: Set(try await db.leafRevisions(id: id)),
                conflicts: try await db.conflicts(id: id), attachmentData: data)
        }
        return result
    }
}
