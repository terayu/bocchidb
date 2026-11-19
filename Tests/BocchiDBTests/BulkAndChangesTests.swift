import Testing
@testable import BocchiDB

@Suite struct BulkDocsTests {
    @Test func reportsResultPerDocument() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "exists", body: ["v": 1])

        let results = try await db.bulkDocs([
            DocumentWrite(id: "a", body: ["v": 1]),
            DocumentWrite(id: "exists", body: ["v": 2]),   // rev なし → 競合
            DocumentWrite(id: "_bad", body: [:]),          // 不正な ID
            DocumentWrite(id: "b", body: ["v": 2]),
        ])

        #expect(try results[0].get().generation == 1)
        #expect(results[1].error == .conflict)
        #expect(results[2].error == .invalidDocumentID("_bad"))
        #expect(try results[3].get().generation == 1)

        // 失敗した文書があっても、成功した文書は保存される。
        #expect(try await db.get(id: "a") != nil)
        #expect(try await db.get(id: "b") != nil)
        #expect(try await db.get(id: "exists")?.body == ["v": 1])
    }

    @Test func updatesAndDeletes() async throws {
        let db = try BocchiDB(path: ":memory:")
        let revA = try await db.put(id: "a", body: ["v": 1])
        let revB = try await db.put(id: "b", body: ["v": 1])

        let results = try await db.bulkDocs([
            DocumentWrite(id: "a", rev: revA, body: ["v": 2]),
            DocumentWrite(id: "b", rev: revB, deleted: true),
        ])

        #expect(results.allSatisfy { $0.error == nil })
        #expect(try await db.get(id: "a")?.body == ["v": 2])
        #expect(try await db.get(id: "b") == nil)
    }
}

@Suite struct AllDocsTests {
    @Test func returnsLiveDocumentsSortedByID() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "b", body: ["v": "b"])
        try await db.put(id: "a", body: ["v": "a"])
        let revC = try await db.put(id: "c", body: ["v": "c"])
        try await db.remove(id: "c", rev: revC)
        try await db.put(id: "_design/x", body: [:])

        let ids = try await db.allDocs().map(\.id)
        #expect(ids == ["_design/x", "a", "b"])
    }

    @Test func returnsWinnerOfConflictedDocument() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.merge(id: "a", path: [RevisionID("2-b")!, RevisionID("1-a")!], deleted: false, body: ["v": "b"])
        try await db.merge(id: "a", path: [RevisionID("2-c")!, RevisionID("1-a")!], deleted: false, body: ["v": "c"])
        #expect(try await db.allDocs().map(\.body) == [["v": "c"]])
    }
}

@Suite struct ChangesTests {
    @Test func listsEachDocumentOnceAtLatestSeq() async throws {
        let db = try BocchiDB(path: ":memory:")
        let revA = try await db.put(id: "a", body: ["v": 1])
        try await db.put(id: "b", body: ["v": 1])
        let revA2 = try await db.put(id: "a", body: ["v": 2], rev: revA)

        let changes = try await db.changes()
        #expect(changes.results.map(\.id) == ["b", "a"])
        #expect(changes.results.map(\.seq) == [2, 3])
        #expect(changes.results[1].revs == [revA2])
        #expect(changes.lastSeq == 3)
    }

    @Test func includesDeletedDocuments() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev = try await db.put(id: "a", body: [:])
        let deletedRev = try await db.remove(id: "a", rev: rev)

        let change = try #require(try await db.changes().results.first)
        #expect(change.deleted)
        #expect(change.revs == [deletedRev])
    }

    @Test func filtersBySinceAndLimit() async throws {
        let db = try BocchiDB(path: ":memory:")
        for id in ["a", "b", "c", "d"] {
            try await db.put(id: id, body: [:])
        }

        let page = try await db.changes(since: 1, limit: 2)
        #expect(page.results.map(\.id) == ["b", "c"])
        #expect(page.lastSeq == 3)

        let rest = try await db.changes(since: page.lastSeq)
        #expect(rest.results.map(\.id) == ["d"])
        #expect(rest.lastSeq == 4)
    }

    @Test func returnsSinceWhenNothingChanged() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "a", body: [:])
        let changes = try await db.changes(since: 1)
        #expect(changes.results.isEmpty)
        #expect(changes.lastSeq == 1)
    }

    /// style=all_docs 相当：競合を含む全リーフを、勝者を先頭にして返す。
    @Test func includesAllLeavesWinnerFirst() async throws {
        let db = try BocchiDB(path: ":memory:")
        let a = RevisionID("1-a")!, b = RevisionID("2-b")!, c = RevisionID("2-c")!, z = RevisionID("3-z")!
        try await db.merge(id: "doc", path: [z, b, a], deleted: true, body: [:])
        try await db.merge(id: "doc", path: [c, a], deleted: false, body: ["v": "c"])

        let change = try #require(try await db.changes().results.first)
        #expect(change.revs == [c, z])
        #expect(change.deleted == false)
    }
}

@Suite struct LocalDocumentTests {
    @Test func putGetAndRemove() async throws {
        let db = try BocchiDB(path: ":memory:")
        #expect(try await db.getLocal(id: "checkpoint") == nil)

        try await db.putLocal(id: "checkpoint", body: ["last_seq": "10-abc"])
        #expect(try await db.getLocal(id: "checkpoint") == ["last_seq": "10-abc"])

        try await db.putLocal(id: "checkpoint", body: ["last_seq": "20-def"])
        #expect(try await db.getLocal(id: "checkpoint") == ["last_seq": "20-def"])

        try await db.removeLocal(id: "checkpoint")
        #expect(try await db.getLocal(id: "checkpoint") == nil)
    }

    @Test func isNotPartOfDocumentsOrChanges() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.putLocal(id: "checkpoint", body: ["last_seq": 1])
        #expect(try await db.allDocs().isEmpty)
        #expect(try await db.changes().results.isEmpty)
    }
}

private extension Result {
    var error: Failure? {
        if case .failure(let error) = self { error } else { nil }
    }
}
