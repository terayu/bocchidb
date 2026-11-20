import Foundation
import Testing
@testable import BocchiDB

@Suite struct FindTests {
    /// 各テストで使う文書。
    private static let fixtures: [String: [String: JSONValue]] = [
        "n1": ["v": 1, "type": "num"],
        "n2": ["v": 2.5, "type": "num"],
        "s1": ["v": "a", "type": "str"],
        "s2": ["v": "B", "type": "str"],
        "nul": ["v": nil],
        "t": ["v": true],
        "arr": ["v": [1, 2], "tags": ["x", "y"]],
        "obj": ["v": ["x": 1], "user": ["name": "ruth", "age": 30]],
        "none": ["w": 1],
    ]

    private func makeDB() async throws -> BocchiDB {
        let db = try BocchiDB(path: ":memory:")
        for (id, body) in Self.fixtures { try await db.put(id: id, body: body) }
        return db
    }

    private func ids(_ db: BocchiDB, _ selector: JSONValue, sort: [SortField] = []) async throws -> [String] {
        try await db.find(FindQuery(selector: selector, sort: sort)).map(\.id)
    }

    // MARK: - 比較規則

    @Test func collationOrdersTypesThenValues() {
        let values: [JSONValue] = [nil, false, true, -1, 2.5, 3, "", "a", "A", "b", "あ", "ア", "い", [1], [1, 2], [2], ["a": 1]]
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(Collation.compare(a, b) == .orderedAscending, "\(a) < \(b)")
            #expect(Collation.compare(b, a) == .orderedDescending)
        }
        #expect(Collation.compare(1, 1.0) == .orderedSame)
        #expect(Collation.compare("\u{e9}", "e\u{301}") == .orderedSame)  // Unicode として等価
    }

    @Test func rawComparisonUsesUTF8Bytes() {
        #expect(Collation.compareRaw("Z", "a") == .orderedAscending)  // 照合順序では "a" < "Z"
        #expect(Collation.compare("Z", "a") == .orderedDescending)
        #expect(Collation.compareRaw("é", "あ") == .orderedAscending)
    }

    // MARK: - 演算子

    @Test func equalityAndNestedFields() async throws {
        let db = try await makeDB()
        #expect(try await ids(db, ["v": 1]) == ["n1"])
        #expect(try await ids(db, ["v": 1.0]) == ["n1"])
        #expect(try await ids(db, ["user": ["name": "ruth"]]) == ["obj"])
        #expect(try await ids(db, ["user.name": "ruth"]) == ["obj"])
        #expect(try await ids(db, ["v": ["x": 1]]) == ["obj"])
        #expect(try await ids(db, ["v": nil]) == ["nul"])
        #expect(try await ids(db, ["tags.1": "y"]) == ["arr"])
        #expect(try await ids(db, ["_id": "t"]) == ["t"])
        #expect(try await ids(db, [:]).count == Self.fixtures.count)
    }

    @Test func escapedDotIsPartOfFieldName() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "a", body: ["x.y": 1])
        try await db.put(id: "b", body: ["x": ["y": 1]])
        #expect(try await ids(db, [#"x\.y"#: 1]) == ["a"])
        #expect(try await ids(db, ["x.y": 1]) == ["b"])
    }

    @Test func comparisonsFollowCollationAcrossTypes() async throws {
        let db = try await makeDB()
        #expect(try await ids(db, ["v": ["$gt": 2]]) == ["arr", "n2", "obj", "s1", "s2"])
        #expect(try await ids(db, ["v": ["$lt": "a"]]) == ["n1", "n2", "nul", "t"])
        #expect(try await ids(db, ["v": ["$gte": 1, "$lte": 2.5]]) == ["n1", "n2"])
    }

    @Test func negationNeverMatchesMissingField() async throws {
        let db = try await makeDB()
        let notOne = ["arr", "n2", "nul", "obj", "s1", "s2", "t"]
        #expect(try await ids(db, ["v": ["$ne": 1]]) == notOne)
        #expect(try await ids(db, ["$not": ["v": 1]]) == notOne)
        #expect(try await ids(db, ["$nor": [["v": 1]]]) == notOne)
        #expect(try await ids(db, ["v": ["$not": ["$eq": 1]]]) == notOne)
        // $exists だけは否定するとフィールドがない文書に一致する。
        #expect(try await ids(db, ["$not": ["v": ["$exists": true]]]) == ["none"])
        #expect(try await ids(db, ["v": ["$exists": false]]) == ["none"])
    }

    @Test func combinationOperators() async throws {
        let db = try await makeDB()
        #expect(try await ids(db, ["$or": [["v": 1], ["v": "a"]]]) == ["n1", "s1"])
        #expect(try await ids(db, ["$and": [["type": "num"], ["v": ["$gt": 1]]]]) == ["n2"])
        #expect(try await ids(db, ["$not": ["$or": [["type": "num"], ["type": "str"]]]]) == [])
        #expect(try await ids(db, ["type": ["$or": [["$eq": "num"], ["$eq": "str"]]]]) == ["n1", "n2", "s1", "s2"])
    }

    @Test func arrayOperators() async throws {
        let db = try await makeDB()
        #expect(try await ids(db, ["v": ["$in": [2, "a"]]]) == ["arr", "s1"])  // 配列は要素で照合
        #expect(try await ids(db, ["tags": ["$nin": ["x"]]]) == [])
        #expect(try await ids(db, ["v": ["$all": [1]]]) == ["arr"])
        #expect(try await ids(db, ["v": ["$all": [[1, 2]]]]) == ["arr"])
        #expect(try await ids(db, ["v": ["$size": 2]]) == ["arr"])
        #expect(try await ids(db, ["v": ["$elemMatch": ["$gt": 1]]]) == ["arr"])
        #expect(try await ids(db, ["v": ["$allMatch": ["$gt": 1]]]) == [])
        #expect(try await ids(db, ["v": ["$allMatch": ["$gte": 1]]]) == ["arr"])
    }

    @Test func valueOperators() async throws {
        let db = try await makeDB()
        #expect(try await ids(db, ["v": ["$type": "string"]]) == ["s1", "s2"])
        #expect(try await ids(db, ["v": ["$type": "number"]]) == ["n1", "n2"])
        #expect(try await ids(db, ["v": ["$mod": [2, 1]]]) == ["n1"])  // 小数は対象外
        #expect(try await ids(db, ["type": ["$regex": "^s"]]) == ["s1", "s2"])
        #expect(try await ids(db, ["user.name": ["$beginsWith": "ru"]]) == ["obj"])
    }

    @Test func excludesDeletedAndDesignDocuments() async throws {
        let db = try await makeDB()
        try await db.put(id: "_design/d", body: ["v": 1])
        let rev = try #require(try await db.get(id: "n1")?.rev)
        try await db.remove(id: "n1", rev: rev)
        #expect(try await ids(db, ["v": 1]) == [])
    }

    // MARK: - 並べ替え・件数・フィールド

    @Test func sortsByCollationAndDropsDocumentsWithoutSortField() async throws {
        let db = try await makeDB()
        let ascending = ["nul", "t", "n1", "n2", "s1", "s2", "arr", "obj"]
        #expect(try await ids(db, [:], sort: [SortField("v")]) == ascending)
        #expect(try await ids(db, [:], sort: [SortField("v", .descending)]) == ascending.reversed())
        // 同じ値は _id 順
        #expect(try await ids(db, ["type": "num"], sort: [SortField("type")]) == ["n1", "n2"])
    }

    @Test func appliesSkipAndLimitAfterSorting() async throws {
        let db = try await makeDB()
        let docs = try await db.find(FindQuery(selector: [:], sort: [SortField("v")], limit: 2, skip: 1))
        #expect(docs.map(\.id) == ["t", "n1"])
    }

    @Test func projectsFields() async throws {
        let db = try await makeDB()
        let rev = try await db.putAttachment(id: "obj", name: "a.txt", contentType: "text/plain", data: Data("x".utf8),
                                             rev: try await db.get(id: "obj")?.rev)

        let projected = try #require(try await db.find(FindQuery(selector: ["_id": "obj"], fields: ["user.name", "missing"])).first)
        #expect(projected.id == "obj")
        #expect(projected.rev == rev)
        #expect(projected.body == ["user": ["name": "ruth"]])
        #expect(projected.attachments.isEmpty)

        let withAttachments = try await db.find(FindQuery(selector: ["_id": "obj"], fields: ["_attachments"]))
        #expect(withAttachments.first?.body == [:])
        #expect(withAttachments.first?.attachments.keys.sorted() == ["a.txt"])
        #expect(try await db.find(FindQuery(selector: ["_id": "obj"])).first?.attachments.count == 1)
    }

    @Test func worksOnReadOnlyDatabase() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bocchidb-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        do {
            let db = try BocchiDB(url: url)
            try await db.put(id: "a", body: ["v": 1])
        }
        let db = try BocchiDB(url: url, mode: .readOnly)
        #expect(try await db.find(FindQuery(selector: ["v": 1])).map(\.id) == ["a"])
    }

    // MARK: - クエリの JSON と検証

    @Test func parsesQueryJSON() throws {
        let query = try FindQuery(json: Data(#"""
            {"selector": {"v": {"$gt": 1}}, "sort": ["a", {"b": "asc"}], "limit": 5, "skip": 2, "fields": ["v"]}
            """#.utf8))
        #expect(query == FindQuery(selector: ["v": ["$gt": 1]], sort: [SortField("a"), SortField("b")],
                                   limit: 5, skip: 2, fields: ["v"]))
    }

    @Test(arguments: [
        #"[]"#, #"{}"#, #"{"selector": {}, "bookmark": "x"}"#, #"{"selector": {}, "sort": [{"a": "up"}]}"#,
        #"{"selector": {}, "limit": "1"}"#, #"{"selector": {}, "fields": [1]}"#,
    ])
    func rejectsInvalidQueryJSON(json: String) {
        #expect(throws: BocchiDBError.self) { try FindQuery(json: Data(json.utf8)) }
    }

    @Test(arguments: [
        FindQuery(selector: "x"),
        FindQuery(selector: ["v": ["$foo": 1]]),
        FindQuery(selector: ["v": ["$in": 1]]),
        FindQuery(selector: ["v": ["$exists": 1]]),
        FindQuery(selector: ["v": ["$type": "date"]]),
        FindQuery(selector: ["v": ["$mod": [0, 1]]]),
        FindQuery(selector: ["v": ["$regex": "("]]),
        FindQuery(selector: ["$and": ["v"]]),
        FindQuery(selector: [:], sort: [SortField("a"), SortField("b", .descending)]),
        FindQuery(selector: [:], limit: -1),
    ])
    func rejectsInvalidQuery(query: FindQuery) async throws {
        let db = try BocchiDB(path: ":memory:")
        await #expect {
            try await db.find(query)
        } throws: { error in
            if case BocchiDBError.invalidQuery = error { true } else { false }
        }
    }
}
