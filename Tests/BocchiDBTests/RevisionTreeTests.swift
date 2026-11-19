import Testing
@testable import BocchiDB

@Suite struct RevisionTreeTests {
    private func revs(_ strings: String...) -> [RevisionID] {
        strings.map { RevisionID($0)! }
    }

    private func leafStrings(_ tree: RevisionTree) -> Set<String> {
        Set(tree.leaves.map(\.rev.description))
    }

    @Test func mergesFirstRevisionIntoEmptyTree() throws {
        var tree = RevisionTree()
        #expect(try tree.merge(path: revs("1-a"), deleted: false) == revs("1-a"))
        #expect(leafStrings(tree) == ["1-a"])
        #expect(tree.parent(of: RevisionID("1-a")!) == nil)
    }

    @Test func extendsExistingLeaf() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("1-a"), deleted: false)
        #expect(try tree.merge(path: revs("2-b", "1-a"), deleted: false) == revs("2-b"))
        #expect(leafStrings(tree) == ["2-b"])
    }

    @Test func mergeIsIdempotent() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("2-b", "1-a"), deleted: false)
        #expect(try tree.merge(path: revs("2-b", "1-a"), deleted: false).isEmpty)
        #expect(try tree.merge(path: revs("1-a"), deleted: false).isEmpty)
        #expect(leafStrings(tree) == ["2-b"])
    }

    @Test func branchesOnConflict() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("2-b", "1-a"), deleted: false)
        try tree.merge(path: revs("2-c", "1-a"), deleted: false)
        #expect(leafStrings(tree) == ["2-b", "2-c"])
    }

    @Test func fillsMissingIntermediateRevisions() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("1-a"), deleted: false)
        let inserted = try tree.merge(path: revs("4-d", "3-c", "2-b", "1-a"), deleted: false)
        #expect(inserted == revs("2-b", "3-c", "4-d"))  // 古い順
        #expect(leafStrings(tree) == ["4-d"])
        #expect(tree.parent(of: RevisionID("2-b")!) == RevisionID("1-a"))
    }

    @Test func addsUnrelatedHistoryAsNewRoot() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("2-b", "1-a"), deleted: false)
        try tree.merge(path: revs("2-y", "1-x"), deleted: false)
        #expect(leafStrings(tree) == ["2-b", "2-y"])
        #expect(tree.parent(of: RevisionID("1-x")!) == nil)
    }

    @Test func keepsDeletedFlagOnlyOnNewestRevision() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("3-c", "2-b", "1-a"), deleted: true)
        #expect(tree.leaves == [LeafRevision(rev: RevisionID("3-c")!, deleted: true)])
        #expect(tree.isDeleted(RevisionID("2-b")!) == false)
    }

    @Test(arguments: [["2-b", "2-a"], ["3-c", "1-a"], ["1-a", "2-b"]])
    func rejectsNonConsecutivePath(_ path: [String]) {
        var tree = RevisionTree()
        #expect(throws: BocchiDBError.invalidRevisionHistory) {
            try tree.merge(path: path.map { RevisionID($0)! }, deleted: false)
        }
    }

    @Test func rejectsEmptyPath() {
        var tree = RevisionTree()
        #expect(throws: BocchiDBError.invalidRevisionHistory) {
            try tree.merge(path: [], deleted: false)
        }
    }

    @Test func stemsHistoryBeyondLimit() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("4-d", "3-c", "2-b", "1-a"), deleted: false)
        let result = tree.stem(limit: 2)
        #expect(Set(result.removed) == Set(revs("1-a", "2-b")))
        #expect(result.newRoots == revs("3-c"))
        #expect(tree.contains(RevisionID("3-c")!))
        #expect(!tree.contains(RevisionID("2-b")!))
        #expect(tree.parent(of: RevisionID("3-c")!) == nil)
    }

    /// 片方のブランチにとって limit 内にある祖先は残す。
    @Test func stemKeepsAncestorsNeededByAnyLeaf() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("4-d", "3-c", "2-b", "1-a"), deleted: false)
        try tree.merge(path: revs("2-x", "1-a"), deleted: false)
        let result = tree.stem(limit: 2)
        #expect(Set(result.removed) == Set(revs("2-b")))
        #expect(result.newRoots == revs("3-c"))
        #expect(tree.parent(of: RevisionID("2-x")!) == RevisionID("1-a"))
    }

    @Test func stemWithinLimitChangesNothing() throws {
        var tree = RevisionTree()
        try tree.merge(path: revs("2-b", "1-a"), deleted: false)
        let result = tree.stem(limit: 1000)
        #expect(result.removed.isEmpty)
        #expect(result.newRoots.isEmpty)
    }
}
