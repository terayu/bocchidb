import Testing
@testable import BocchiDB

/// `stream` から `id` の変更が届くまで待つ。
func nextChange(_ stream: AsyncStream<Change>, id: String) async -> Change? {
    for await change in stream where change.id == id { return change }
    return nil
}

@Suite(.timeLimit(.minutes(1))) struct ObserveChangesTests {
    @Test func notifiesPut() async throws {
        let db = try BocchiDB(path: ":memory:")
        let stream = await db.observeChanges()
        let rev = try await db.put(id: "a", body: ["v": 1])

        let change = await nextChange(stream, id: "a")
        #expect(change?.revs == [rev])
        #expect(change?.deleted == false)
    }

    @Test func notifiesRemove() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev = try await db.put(id: "a", body: [:])
        let stream = await db.observeChanges()
        try await db.remove(id: "a", rev: rev)
        #expect(await nextChange(stream, id: "a")?.deleted == true)
    }

    @Test func notifiesEachDocumentOfBulkDocs() async throws {
        let db = try BocchiDB(path: ":memory:")
        let stream = await db.observeChanges()
        _ = try await db.bulkDocs([DocumentWrite(id: "a"), DocumentWrite(id: "b")])

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.id == "a")
        #expect(await iterator.next()?.id == "b")
    }

    /// 同期で取り込んだ変更（merge）も通知される。
    @Test func notifiesMergedRevision() async throws {
        let db = try BocchiDB(path: ":memory:")
        let stream = await db.observeChanges()
        try await db.merge(id: "a", path: [RevisionID("2-b")!, RevisionID("1-a")!], deleted: false, body: [:])
        #expect(await nextChange(stream, id: "a")?.revs == [RevisionID("2-b")!])
    }

    @Test func doesNotNotifyChangesBeforeSubscription() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "before", body: [:])
        let stream = await db.observeChanges()
        try await db.put(id: "after", body: [:])

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.id == "after")
    }

    @Test func doesNotNotifyFailedOrNoOpWrites() async throws {
        let db = try BocchiDB(path: ":memory:")
        let path = [RevisionID("1-a")!]
        try await db.merge(id: "a", path: path, deleted: false, body: [:])
        let stream = await db.observeChanges()

        try await db.merge(id: "a", path: path, deleted: false, body: [:])  // すでにある
        await #expect(throws: BocchiDBError.conflict) { try await db.put(id: "a", body: [:]) }
        try await db.put(id: "marker", body: [:])

        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.id == "marker")
    }

    @Test func notifiesAllObservers() async throws {
        let db = try BocchiDB(path: ":memory:")
        let first = await db.observeChanges()
        let second = await db.observeChanges()
        try await db.put(id: "a", body: [:])
        #expect(await nextChange(first, id: "a") != nil)
        #expect(await nextChange(second, id: "a") != nil)
    }

    @Test func unregistersWhenIterationIsCancelled() async throws {
        let db = try BocchiDB(path: ":memory:")
        let stream = await db.observeChanges()
        let task = Task { for await _ in stream {} }
        #expect(await db.observerCount == 1)

        task.cancel()
        await task.value
        while await db.observerCount > 0 { await Task.yield() }
        #expect(await db.observerCount == 0)
    }
}
