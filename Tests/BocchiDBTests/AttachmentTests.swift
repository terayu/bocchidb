import Foundation
import Testing
@testable import BocchiDB

@Suite struct AttachmentTests {
    private let photo = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
    private let other = Data([0x01, 0x02, 0x03])

    @Test func putAttachmentCreatesDocument() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        #expect(rev.generation == 1)

        let doc = try #require(try await db.get(id: "a"))
        #expect(doc.body.isEmpty)
        #expect(doc.attachments == ["photo.jpg": AttachmentInfo(
            contentType: "image/jpeg", digest: AttachmentInfo.digest(of: photo), length: 6, revpos: 1)])
        #expect(try await db.attachment(id: "a", name: "photo.jpg") == photo)
    }

    @Test func digestIsMD5OfData() {
        // printf 'hello' | openssl md5 -binary | base64
        #expect(AttachmentInfo.digest(of: Data("hello".utf8)) == "md5-XUFAKrxLKna5cZ2REBfFkg==")
    }

    @Test func putAttachmentKeepsBodyAndOtherAttachments() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.put(id: "a", body: ["temperature": 25.5])
        let rev2 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo, rev: rev1)
        try await db.putAttachment(id: "a", name: "memo.txt", contentType: "text/plain", data: other, rev: rev2)

        let doc = try #require(try await db.get(id: "a"))
        #expect(doc.body == ["temperature": 25.5])
        #expect(doc.attachments["photo.jpg"]?.revpos == 2)
        #expect(doc.attachments["memo.txt"]?.revpos == 3)
    }

    /// 本文だけの更新では、添付は revpos を保ったまま引き継がれる。
    @Test func putKeepsAttachments() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        try await db.put(id: "a", body: ["v": 2], rev: rev1)

        let doc = try #require(try await db.get(id: "a"))
        #expect(doc.attachments["photo.jpg"]?.revpos == 1)
        #expect(try await db.attachment(id: "a", name: "photo.jpg") == photo)
    }

    @Test func replacingAttachmentDropsOldData() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: other, rev: rev1)
        #expect(try await db.attachment(id: "a", name: "photo.jpg") == other)
        #expect(try await db.attachmentBlobCount() == 1)
    }

    @Test func removeAttachment() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        let rev2 = try await db.removeAttachment(id: "a", name: "photo.jpg", rev: rev1)
        #expect(try await db.get(id: "a")?.attachments.isEmpty == true)
        #expect(try await db.attachment(id: "a", name: "photo.jpg") == nil)
        #expect(try await db.attachmentBlobCount() == 0)

        await #expect(throws: BocchiDBError.attachmentNotFound("photo.jpg")) {
            try await db.removeAttachment(id: "a", name: "photo.jpg", rev: rev2)
        }
    }

    @Test func deletingDocumentDropsAttachments() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        try await db.remove(id: "a", rev: rev1)
        #expect(try await db.attachmentBlobCount() == 0)

        try await db.put(id: "a", body: [:])  // 作り直しても添付は戻らない
        #expect(try await db.get(id: "a")?.attachments.isEmpty == true)
    }

    @Test func sameDataIsStoredOnce() async throws {
        let db = try BocchiDB(path: ":memory:")
        let revA = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        try await db.putAttachment(id: "b", name: "copy.jpg", contentType: "image/jpeg", data: photo)
        #expect(try await db.attachmentBlobCount() == 1)

        // 片方が手放しても、もう片方が参照している間は残る。
        try await db.removeAttachment(id: "a", name: "photo.jpg", rev: revA)
        #expect(try await db.attachment(id: "b", name: "copy.jpg") == photo)
    }

    @Test func attachmentAffectsRevisionID() async throws {
        let rev1 = try await BocchiDB(path: ":memory:")
            .putAttachment(id: "a", name: "x", contentType: "application/octet-stream", data: photo)
        let rev2 = try await BocchiDB(path: ":memory:")
            .putAttachment(id: "a", name: "x", contentType: "application/octet-stream", data: other)
        #expect(rev1 != rev2)
    }

    @Test func readsAttachmentOfSpecificRevision() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.merge(id: "a", path: [RevisionID("2-b")!, RevisionID("1-a")!], deleted: false, body: [:],
                           attachments: ["x": IncomingAttachment(contentType: "text/plain", revpos: 2, data: photo)])
        try await db.merge(id: "a", path: [RevisionID("2-c")!, RevisionID("1-a")!], deleted: false, body: [:],
                           attachments: ["x": IncomingAttachment(contentType: "text/plain", revpos: 2, data: other)])
        #expect(try await db.attachment(id: "a", name: "x") == other)  // 勝者 2-c
        #expect(try await db.attachment(id: "a", name: "x", rev: RevisionID("2-b")!) == photo)
    }

    @Test(arguments: ["", "_private"])
    func rejectsInvalidName(_ name: String) async throws {
        let db = try BocchiDB(path: ":memory:")
        await #expect(throws: BocchiDBError.invalidAttachment(name)) {
            try await db.putAttachment(id: "a", name: name, contentType: "text/plain", data: photo)
        }
    }

    @Test func putAttachmentWithStaleRevisionConflicts() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.put(id: "a", body: [:])
        try await db.put(id: "a", body: ["v": 2], rev: rev1)
        await #expect(throws: BocchiDBError.conflict) {
            try await db.putAttachment(id: "a", name: "x", contentType: "text/plain", data: photo, rev: rev1)
        }
    }

    // MARK: - 同期での取り込み

    /// stub は、ローカルの祖先にある同じ名前・revpos の添付で解決する。
    @Test func mergeResolvesStubFromAncestor() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        let rev2 = try #require(RevisionID("2-remote"))
        // CouchDB の stub の digest はローカルと一致しないことがあるが、名前と revpos で解決するので問題ない。
        try await db.merge(id: "a", path: [rev2, rev1], deleted: false, body: ["v": 2],
                           attachments: ["photo.jpg": IncomingAttachment(contentType: "image/jpeg", revpos: 1, data: nil)])

        let doc = try #require(try await db.get(id: "a"))
        #expect(doc.rev == rev2)
        #expect(doc.attachments["photo.jpg"]?.digest == AttachmentInfo.digest(of: photo))
        #expect(try await db.attachment(id: "a", name: "photo.jpg") == photo)
    }

    @Test func mergeRejectsUnresolvableStub() async throws {
        let db = try BocchiDB(path: ":memory:")
        await #expect(throws: BocchiDBError.invalidAttachment("photo.jpg")) {
            try await db.merge(id: "a", path: [RevisionID("2-b")!, RevisionID("1-a")!], deleted: false, body: [:],
                               attachments: ["photo.jpg": IncomingAttachment(contentType: "image/jpeg", revpos: 1, data: nil)])
        }
    }

    @Test func persistsAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bocchidb-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try await BocchiDB(url: url).putAttachment(id: "a", name: "photo.jpg", contentType: "image/jpeg", data: photo)
        #expect(try await BocchiDB(url: url).attachment(id: "a", name: "photo.jpg") == photo)
    }
}
