import Foundation
import Testing
@testable import BocchiDB

@Suite struct BocchiDBTests {
    private func makeDB(revsLimit: Int = 1000) throws -> BocchiDB {
        try BocchiDB(path: ":memory:", revsLimit: revsLimit)
    }

    private func rev(_ string: String) -> RevisionID { RevisionID(string)! }

    // MARK: - put / get

    @Test func putCreatesFirstRevision() async throws {
        let db = try makeDB()
        let rev = try await db.put(id: "inspection-001", body: ["temperature": 25.5])
        #expect(rev.generation == 1)
        #expect(rev.hash.count == 32)

        let doc = try await db.get(id: "inspection-001")
        #expect(doc == Document(id: "inspection-001", rev: rev, deleted: false, body: ["temperature": 25.5]))
    }

    @Test func getReturnsNilForMissingDocument() async throws {
        let db = try makeDB()
        #expect(try await db.get(id: "nothing") == nil)
    }

    @Test func updateWithCurrentRevision() async throws {
        let db = try makeDB()
        let rev1 = try await db.put(id: "a", body: ["v": 1])
        let rev2 = try await db.put(id: "a", body: ["v": 2], rev: rev1)
        #expect(rev2.generation == 2)
        #expect(try await db.get(id: "a")?.body == ["v": 2])
    }

    @Test func putWithoutRevisionOnExistingDocumentConflicts() async throws {
        let db = try makeDB()
        try await db.put(id: "a", body: ["v": 1])
        await #expect(throws: BocchiDBError.conflict) {
            try await db.put(id: "a", body: ["v": 2])
        }
    }

    @Test func putWithStaleRevisionConflicts() async throws {
        let db = try makeDB()
        let rev1 = try await db.put(id: "a", body: ["v": 1])
        try await db.put(id: "a", body: ["v": 2], rev: rev1)
        await #expect(throws: BocchiDBError.conflict) {
            try await db.put(id: "a", body: ["v": 3], rev: rev1)
        }
    }

    @Test func putWithRevisionOnMissingDocumentConflicts() async throws {
        let db = try makeDB()
        await #expect(throws: BocchiDBError.conflict) {
            try await db.put(id: "a", body: [:], rev: rev("1-abc"))
        }
    }

    /// 同じ親・同じ内容なら、別の DB でも同じ rev になる。
    @Test func revisionIDIsDeterministic() async throws {
        let rev1 = try await makeDB().put(id: "a", body: ["x": 1, "y": "z"])
        let rev2 = try await makeDB().put(id: "a", body: ["y": "z", "x": 1])
        #expect(rev1 == rev2)
    }

    @Test func oldRevisionBodyIsDiscarded() async throws {
        let db = try makeDB()
        let rev1 = try await db.put(id: "a", body: ["v": 1])
        let rev2 = try await db.put(id: "a", body: ["v": 2], rev: rev1)
        #expect(try await db.get(id: "a", rev: rev1) == nil)
        #expect(try await db.get(id: "a", rev: rev2)?.body == ["v": 2])
    }

    // MARK: - 検証

    @Test(arguments: ["", "_foo", "_local/x"])
    func rejectsInvalidDocumentID(_ id: String) async throws {
        let db = try makeDB()
        await #expect(throws: BocchiDBError.invalidDocumentID(id)) {
            try await db.put(id: id, body: [:])
        }
    }

    @Test func acceptsDesignDocumentID() async throws {
        let db = try makeDB()
        try await db.put(id: "_design/app", body: ["language": "query"])
        #expect(try await db.get(id: "_design/app") != nil)
    }

    @Test func rejectsReservedBodyKey() async throws {
        let db = try makeDB()
        await #expect(throws: BocchiDBError.invalidBody("_rev")) {
            try await db.put(id: "a", body: ["_rev": "1-abc"])
        }
    }

    // MARK: - remove

    @Test func removeHidesDocument() async throws {
        let db = try makeDB()
        let rev1 = try await db.put(id: "a", body: ["v": 1])
        let rev2 = try await db.remove(id: "a", rev: rev1)
        #expect(rev2.generation == 2)
        #expect(try await db.get(id: "a") == nil)
        #expect(try await db.get(id: "a", rev: rev2)?.deleted == true)
    }

    @Test func recreateAfterRemoveContinuesHistory() async throws {
        let db = try makeDB()
        let rev1 = try await db.put(id: "a", body: ["v": 1])
        try await db.remove(id: "a", rev: rev1)
        let rev3 = try await db.put(id: "a", body: ["v": 3])
        #expect(rev3.generation == 3)
        #expect(try await db.get(id: "a")?.body == ["v": 3])
    }

    // MARK: - 競合（new_edits=false 相当のマージ）

    /// interop/check-conflict.mjs と同じ状況を再現する。
    @Test func mergeCreatesConflictWithCouchDBWinner() async throws {
        let db = try makeDB()
        let root = rev("1-0f0a6e0ab1d24b5c9c3b1c1f0e4a6d52")
        let a = rev("2-a15bcff0fbc694de65ee800f83be0b58")
        let b = rev("2-a7206904c7b66385d7757b3aae9d07c8")
        try await db.merge(id: "inspection-001", path: [root], deleted: false, body: ["temperature": 25.5])
        try await db.merge(id: "inspection-001", path: [a, root], deleted: false, body: ["temperature": 26.0])
        try await db.merge(id: "inspection-001", path: [b, root], deleted: false, body: ["temperature": 27])

        let doc = try await db.get(id: "inspection-001")
        #expect(doc?.rev == b)
        #expect(doc?.body == ["temperature": 27])
        #expect(try await db.conflicts(id: "inspection-001") == [a])
    }

    @Test func mergeIsIdempotent() async throws {
        let db = try makeDB()
        let path = [rev("2-b"), rev("1-a")]
        #expect(try await db.merge(id: "a", path: path, deleted: false, body: ["v": 2]))
        #expect(try await db.merge(id: "a", path: path, deleted: false, body: ["v": 2]) == false)
        #expect(try await db.get(id: "a")?.rev == rev("2-b"))
    }

    @Test func updatingLosingLeafKeepsBothBranches() async throws {
        let db = try makeDB()
        try await db.merge(id: "a", path: [rev("2-b"), rev("1-a")], deleted: false, body: ["v": "b"])
        try await db.merge(id: "a", path: [rev("2-c"), rev("1-a")], deleted: false, body: ["v": "c"])

        // 敗者 2-b を更新すると 3-x になり、generation で勝者になる。
        let rev3 = try await db.put(id: "a", body: ["v": "b2"], rev: rev("2-b"))
        #expect(try await db.get(id: "a")?.rev == rev3)
        #expect(try await db.conflicts(id: "a") == [rev("2-c")])
    }

    @Test func resolvingConflictByDeletingLoser() async throws {
        let db = try makeDB()
        try await db.merge(id: "a", path: [rev("2-b"), rev("1-a")], deleted: false, body: ["v": "b"])
        try await db.merge(id: "a", path: [rev("2-c"), rev("1-a")], deleted: false, body: ["v": "c"])

        try await db.remove(id: "a", rev: rev("2-b"))
        #expect(try await db.get(id: "a")?.rev == rev("2-c"))
        #expect(try await db.conflicts(id: "a").isEmpty)
    }

    @Test func deletedLeafDoesNotWinOverLiveLeaf() async throws {
        let db = try makeDB()
        try await db.merge(id: "a", path: [rev("3-z"), rev("2-b"), rev("1-a")], deleted: true, body: [:])
        try await db.merge(id: "a", path: [rev("2-c"), rev("1-a")], deleted: false, body: ["v": "c"])
        #expect(try await db.get(id: "a")?.rev == rev("2-c"))
    }

    @Test func stemsHistoryOnWrite() async throws {
        let db = try makeDB(revsLimit: 2)
        var current = try await db.put(id: "a", body: ["v": 0])
        for value in 1...4 {
            current = try await db.put(id: "a", body: ["v": .int(Int64(value))], rev: current)
        }
        #expect(try await db.revisionCount(id: "a") == 2)
        #expect(try await db.get(id: "a")?.rev == current)
    }

    // MARK: - 永続化

    @Test func persistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bocchidb-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let rev = try await BocchiDB(url: url).put(id: "a", body: ["v": 1])
        let doc = try await BocchiDB(url: url).get(id: "a")
        #expect(doc?.rev == rev)
        #expect(doc?.body == ["v": 1])
    }
}
