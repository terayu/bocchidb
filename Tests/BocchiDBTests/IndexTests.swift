import Foundation
import Testing
@testable import BocchiDB

@Suite struct IndexTests {
    // MARK: - キーの形式

    @Test func numberKeysKeepOrder() {
        let numbers: [Double] = [-.infinity, -1e300, -2.5, -1, -0.5, 0, 0.5, 1, 2.5, 1e300, .infinity]
        for (a, b) in zip(numbers, numbers.dropFirst()) {
            #expect(IndexKey.encodeNumber(a).lexicographicallyPrecedes(IndexKey.encodeNumber(b)), "\(a) < \(b)")
        }
        #expect(IndexKey.encodeNumber(-0.0) == IndexKey.encodeNumber(0))
        #expect(IndexKey.encode(.int(26)) == IndexKey.encode(.double(26)))
    }

    @Test func typeTagsFollowCollationOrder() {
        let values: [JSONValue] = [nil, false, true, 1, "a\u{200B}", "a", [1], ["a": 1]]
        for (a, b) in zip(values, values.dropFirst()) {
            #expect(IndexKey.encode(a).lexicographicallyPrecedes(IndexKey.encode(b)), "\(a) < \(b)")
        }
    }

    @Test func simpleStrings() {
        for string in ["", "inspection", "Site-01 (A)", "café", "ひらがな", "カタカナー", "漢字"] {
            #expect(IndexKey.isSimple(string), "\(string)")
        }
        // 無視される文字、分解された文字、半角カナ、全角英字、記号などは内容を保存しない。
        for string in ["a\u{200B}b", "a\u{1}", "e\u{301}", "ｱ", "Ａ", "、", "ゝ", "😀"] {
            #expect(!IndexKey.isSimple(string), "\(string)")
        }
    }

    /// 単純な文字列の範囲では、照合順序で等しいならバイト列も等しい（索引で等価を絞り込む前提）。
    @Test func simpleStringsAreEqualOnlyWhenIdentical() {
        var characters: [String] = []
        for range in [0x20...0x7E, 0xC0...0xFF, 0x3041...0x3096, 0x30A1...0x30FA, 0x30FC...0x30FC] {
            for value in range { if let scalar = Unicode.Scalar(value) { characters.append(String(scalar)) } }
        }
        characters = characters.filter(IndexKey.isSimple)
        let strings = characters + characters.prefix(40).flatMap { a in ["ー", "ア", "a", "ss", "ß"].map { a + $0 } }
        for (i, a) in strings.enumerated() {
            for b in strings[(i + 1)...] where Collation.compare(.string(a), .string(b)) == .orderedSame {
                Issue.record("\(a) と \(b) が照合順序で等しい")
            }
        }
    }

    @Test func successorAndMerging() {
        #expect(IndexKey.successor([0x10, 0xFF]) == [0x11])
        #expect(IndexKey.successor([0xFF, 0xFF]) == nil)
        #expect(KeyInterval.merged([
            KeyInterval(lower: [5], upper: [7]), KeyInterval(lower: [1], upper: [3]),
            KeyInterval(lower: [3], upper: [4]), KeyInterval(lower: [6], upper: nil), KeyInterval(lower: [9], upper: [9]),
        ]) == [KeyInterval(lower: [1], upper: [4]), KeyInterval(lower: [5], upper: nil)])
    }

    // MARK: - 索引の有無で結果が変わらないこと

    private static let stringPool: [JSONValue] = [
        "", "a", "A", "b", "ab", "a\u{200B}b", "a b", "a-b", "é", "e\u{301}", "あ", "ア", "ｱ", "い", "10", "9", "z",
    ]

    private static func randomValue(_ random: inout SeededRandom, depth: Int = 0) -> JSONValue {
        switch Int.random(in: 0..<10, using: &random) {
        case 0: return nil
        case 1: return .bool(Bool.random(using: &random))
        case 2, 3: return .int(Int64.random(in: -3...3, using: &random))
        case 4: return .double([-1.5, 0.5, 2.5, 1e20].randomElement(using: &random)!)
        case 5, 6, 7: return stringPool.randomElement(using: &random)!
        case 8 where depth == 0: return .array((0..<Int.random(in: 0...2, using: &random)).map { _ in randomValue(&random, depth: 1) })
        case 9 where depth == 0: return ["x": randomValue(&random, depth: 1)]
        default: return .int(1)
        }
    }

    private static func randomSelector(_ random: inout SeededRandom) -> JSONValue {
        func condition() -> JSONValue {
            let field = ["v", "w", "o.x", "_id"].randomElement(using: &random)!
            let value = randomValue(&random)
            let op: JSONValue = switch Int.random(in: 0..<12, using: &random) {
            case 0: value
            case 1: ["$gt": value]
            case 2: ["$gte": value]
            case 3: ["$lt": value]
            case 4: ["$lte": value]
            case 5: ["$in": [value, randomValue(&random)]]
            case 6: ["$beginsWith": stringPool.randomElement(using: &random)!]
            case 7: ["$exists": .bool(Bool.random(using: &random))]
            case 8: ["$type": ["null", "boolean", "number", "string", "array", "object"].randomElement(using: &random)!]
            case 9: ["$ne": value]
            case 10: ["$gte": value, "$lt": randomValue(&random)]
            default: ["$not": ["$eq": value]]
            }
            return [field: op]
        }
        return switch Int.random(in: 0..<4, using: &random) {
        case 0: ["$or": [condition(), condition()]]
        case 1: ["$and": [condition(), condition(), condition()]]
        default: ["$and": [condition(), condition()]]
        }
    }

    @Test(arguments: 0..<20)
    func indexedResultsEqualFullScan(seed: UInt64) async throws {
        var random = SeededRandom(seed: seed)
        let db = try BocchiDB(path: ":memory:")
        for i in 0..<120 {
            var body: [String: JSONValue] = [:]
            if Int.random(in: 0..<5, using: &random) > 0 { body["v"] = Self.randomValue(&random) }
            if Int.random(in: 0..<5, using: &random) > 0 { body["w"] = Self.randomValue(&random) }
            if Int.random(in: 0..<3, using: &random) == 0 { body["o"] = ["x": Self.randomValue(&random)] }
            try await db.put(id: String(format: "doc-%03d", i), body: body)
        }
        for fields in [["v"], ["w"], ["v", "w"], ["w", "v"], ["o.x"], ["_id"]] {
            try await db.createIndex(fields: fields)
        }

        var used = 0
        for _ in 0..<150 {
            let query = FindQuery(selector: Self.randomSelector(&random))
            let indexed = try await db.find(query, useIndexes: true).map(\.id)
            if await db.lastFindIndex != nil { used += 1 }
            let scanned = try await db.find(query, useIndexes: false).map(\.id)
            #expect(indexed == scanned, "seed \(seed): \(query.selector)")
        }
        #expect(used > 50, "索引を使った検索が少なすぎる（\(used) 件）")
    }

    // MARK: - 反映

    @Test func reflectsChangesSinceLastSearch() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev = try await db.put(id: "a", body: ["type": "x"])
        try await db.createIndex(fields: ["type"])
        #expect(try await db.find(FindQuery(selector: ["type": "x"])).map(\.id) == ["a"])
        #expect(await db.lastFindIndex != nil)

        try await db.put(id: "b", body: ["type": "x"])
        let rev2 = try await db.put(id: "a", body: ["type": "y"], rev: rev)
        #expect(try await db.find(FindQuery(selector: ["type": "x"])).map(\.id) == ["b"])
        #expect(try await db.find(FindQuery(selector: ["type": "y"])).map(\.id) == ["a"])

        try await db.remove(id: "a", rev: rev2)
        try await db.put(id: "_design/d", body: ["type": "y"])
        #expect(try await db.find(FindQuery(selector: ["type": "y"])).map(\.id) == [])
    }

    @Test func followsWinnerChangedBySync() async throws {
        let db = try BocchiDB(path: ":memory:")
        let rev1 = try await db.put(id: "a", body: ["type": "local"])
        try await db.createIndex(fields: ["type"])
        #expect(try await db.find(FindQuery(selector: ["type": "local"])).map(\.id) == ["a"])

        // 同期で、より新しい世代の競合 Revision が届いて勝者が入れ替わる。
        try await db.merge(id: "a", path: [RevisionID("3-ffff")!, RevisionID("2-eeee")!, rev1], deleted: false,
                           body: ["type": "remote"])
        #expect(try await db.find(FindQuery(selector: ["type": "local"])).map(\.id) == [])
        #expect(try await db.find(FindQuery(selector: ["type": "remote"])).map(\.id) == ["a"])
    }

    @Test func findsStringsWithIgnorableCharacters() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "plain", body: ["v": "ab"])
        try await db.put(id: "zwsp", body: ["v": "a\u{200B}b"])
        try await db.put(id: "other", body: ["v": "abc"])
        try await db.createIndex(fields: ["v"])
        #expect(try await db.find(FindQuery(selector: ["v": "ab"])).map(\.id) == ["plain", "zwsp"])
        #expect(try await db.find(FindQuery(selector: ["v": "a\u{200B}b"])).map(\.id) == ["plain", "zwsp"])
        #expect(await db.lastFindIndex != nil)
    }

    // MARK: - 索引を使う条件

    @Test func usesIndexOnlyWhenAllFieldsAreRequired() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "a", body: ["v": 1, "w": 2])
        try await db.put(id: "b", body: ["v": 1])
        let name = try await db.createIndex(fields: ["v", "w"])

        func indexUsed(_ selector: JSONValue) async throws -> Bool {
            _ = try await db.find(FindQuery(selector: selector))
            return await db.lastFindIndex == name
        }
        #expect(try await indexUsed(["v": 1, "w": ["$gt": 0]]))
        #expect(try await indexUsed(["v": 1, "w": ["$ne": 5]]))
        #expect(try await !indexUsed(["v": 1]))  // w がない文書 b も一致するため使えない
        #expect(try await !indexUsed(["v": 1, "w": ["$exists": false]]))
        #expect(try await !indexUsed(["$or": [["v": 1], ["w": 2]]]))
        #expect(try await db.find(FindQuery(selector: ["v": 1])).map(\.id) == ["a", "b"])
    }

    @Test func choosesMostSelectiveIndex() async throws {
        let db = try BocchiDB(path: ":memory:")
        for i in 0..<50 { try await db.put(id: "d\(i)", body: ["type": "x", "n": .int(Int64(i))]) }
        try await db.createIndex(fields: ["type"], name: "by-type")
        try await db.createIndex(fields: ["n"], name: "by-n")
        #expect(try await db.find(FindQuery(selector: ["type": "x", "n": ["$gte": 48]])).map(\.id) == ["d48", "d49"])
        #expect(await db.lastFindIndex == "by-n")
    }

    // MARK: - _id

    @Test func idConditionsUseDocumentTable() async throws {
        let db = try BocchiDB(path: ":memory:")
        let ids = ["Z", "a", "a\u{10FFFF}", "ab", "abc", "b", "é", "あ", "ア", "inspection-2026-10-31", "inspection-2026-11-01",
                   "inspection-2026-11-30", "inspection-2026-12-01", "site-1"]
        for id in ids { try await db.put(id: id, body: ["n": 1]) }
        try await db.put(id: "_design/x", body: ["n": 1])

        let selectors: [JSONValue] = [
            ["_id": "ab"],
            ["_id": ["$beginsWith": "inspection-2026-11"]],
            ["_id": ["$beginsWith": "a"]],
            ["_id": ["$beginsWith": ""]],
            ["_id": ["$gte": "inspection-2026-11-01", "$lt": "inspection-2026-12-01"]],
            ["_id": ["$gt": "a", "$lte": "b"]],
            ["_id": ["$lt": "a"]],
            ["_id": ["$gt": "é"]],
            ["_id": ["$in": ["a", "あ", 1, "missing"]]],
            ["_id": ["$lt": 5]],
            ["_id": ["$gt": [1]]],
            ["_id": 1],
            ["_id": ["$gt": "a"], "n": 1],
        ]
        // すべての _id に一致する条件では絞り込まない。
        let unrestricted: [JSONValue] = [["_id": ["$gt": nil]], ["_id": ["$lt": ["x": 1]]]]
        for selector in selectors + unrestricted {
            let query = FindQuery(selector: selector)
            let indexed = try await db.find(query, useIndexes: true).map(\.id)
            #expect(await db.lastFindIndex == (unrestricted.contains(selector) ? nil : "_all_docs"), "\(selector)")
            #expect(indexed == (try await db.find(query, useIndexes: false).map(\.id)), "\(selector)")
        }
        #expect(try await db.find(FindQuery(selector: ["_id": ["$beginsWith": "inspection-2026-11"]])).map(\.id)
                == ["inspection-2026-11-01", "inspection-2026-11-30"])
        // 否定や $or では使わない。
        _ = try await db.find(FindQuery(selector: ["_id": ["$ne": "a"]]))
        #expect(await db.lastFindIndex == nil)
    }

    @Test func stringSuccessor() {
        #expect(IndexPlanner.successor(of: "ab") == "ac")
        #expect(IndexPlanner.successor(of: "a\u{10FFFF}") == "b")
        #expect(IndexPlanner.successor(of: "\u{D7FF}") == "\u{E000}")
        #expect(IndexPlanner.successor(of: "") == nil)
    }

    // MARK: - 管理 API

    @Test func managesIndexes() async throws {
        let db = try BocchiDB(path: ":memory:")
        let name = try await db.createIndex(fields: ["type", "date"])
        #expect(name.hasPrefix("idx-"))
        #expect(try await db.createIndex(fields: ["type", "date"]) == name)  // 同じ定義なら同じ名前
        try await db.createIndex(fields: ["n"], name: "custom")
        #expect(try await db.indexes() == [IndexInfo(name: "custom", fields: ["n"]), IndexInfo(name: name, fields: ["type", "date"])])

        try await db.createIndex(fields: ["m"], name: "custom")  // 置き換え
        #expect(try await db.indexes().first == IndexInfo(name: "custom", fields: ["m"]))
        try await db.deleteIndex(name: "custom")
        try await db.deleteIndex(name: "missing")
        #expect(try await db.indexes().map(\.name) == [name])

        await #expect(throws: BocchiDBError.invalidQuery("index fields must not be empty")) {
            try await db.createIndex(fields: [])
        }
    }

    // MARK: - _design 文書の索引

    /// CouchDB の `_index` が作る `_design` 文書と同じ形。
    private static func designDocument(_ indexes: [String: [JSONValue]], partial: JSONValue = [:]) -> [String: JSONValue] {
        ["language": "query", "views": .object(indexes.mapValues { fields in
            ["map": ["fields": [:], "partial_filter_selector": partial], "reduce": "_count",
             "options": ["def": ["fields": .array(fields)]]]
        })]
    }

    @Test func createsIndexesFromDesignDocuments() async throws {
        let db = try BocchiDB(path: ":memory:")
        for i in 0..<10 { try await db.put(id: "d\(i)", body: ["type": "x", "date": .int(Int64(i))]) }
        let rev = try await db.put(id: "_design/inspections", body: Self.designDocument(["by-type-date": ["type", ["date": "desc"]]]))

        // 既定では無効。
        #expect(try await db.designIndexesEnabled() == false)
        _ = try await db.find(FindQuery(selector: ["type": "x", "date": ["$gte": 8]]))
        #expect(await db.lastFindIndex == nil)

        try await db.setDesignIndexesEnabled(true)
        #expect(try await db.indexes() == [IndexInfo(name: "_design/inspections/by-type-date", fields: ["type", "date"])])
        #expect(try await db.find(FindQuery(selector: ["type": "x", "date": ["$gte": 8]])).map(\.id) == ["d8", "d9"])
        #expect(await db.lastFindIndex == "_design/inspections/by-type-date")

        // _design 文書の変更に追従する（索引の追加・フィールドの変更）。
        let rev2 = try await db.put(id: "_design/inspections", body: Self.designDocument([
            "by-type-date": ["date"], "by-type": ["type"],
        ]), rev: rev)
        _ = try await db.find(FindQuery(selector: ["date": 3]))
        #expect(try await db.indexes() == [
            IndexInfo(name: "_design/inspections/by-type", fields: ["type"]),
            IndexInfo(name: "_design/inspections/by-type-date", fields: ["date"]),
        ])
        #expect(await db.lastFindIndex == "_design/inspections/by-type-date")

        // _design 文書を削除すると索引も消える。
        try await db.remove(id: "_design/inspections", rev: rev2)
        #expect(try await db.find(FindQuery(selector: ["date": 3])).map(\.id) == ["d3"])
        #expect(try await db.indexes() == [])
    }

    @Test func ignoresUnsupportedDesignDocuments() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.setDesignIndexesEnabled(true)
        try await db.put(id: "_design/partial", body: Self.designDocument(["p": ["type"]], partial: ["type": "x"]))
        try await db.put(id: "_design/js", body: ["language": "javascript", "views": ["v": ["map": "function(doc) {}"]]])
        try await db.put(id: "_design/broken", body: Self.designDocument(["empty": [], "bad": [1]]))
        try await db.put(id: "_design/ok", body: Self.designDocument(["n": ["n"]]))
        _ = try await db.find(FindQuery(selector: [:]))
        #expect(try await db.indexes().map(\.name) == ["_design/ok/n"])
    }

    @Test func disablingRemovesDesignIndexesOnly() async throws {
        let db = try BocchiDB(path: ":memory:")
        try await db.put(id: "_design/a", body: Self.designDocument(["n": ["n"]]))
        try await db.createIndex(fields: ["m"], name: "mine")
        try await db.setDesignIndexesEnabled(true)
        #expect(try await db.indexes().map(\.name) == ["_design/a/n", "mine"])
        try await db.setDesignIndexesEnabled(false)
        #expect(try await db.indexes().map(\.name) == ["mine"])

        await #expect(throws: BocchiDBError.self) { try await db.createIndex(fields: ["n"], name: "_design/a/n") }
        await #expect(throws: BocchiDBError.self) { try await db.deleteIndex(name: "_design/a/n") }
    }

    // MARK: - 読み取り専用

    private func withFile(_ body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bocchidb-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        try await body(url)
    }

    @Test func readOnlyUsesOnlyUpToDateIndexes() async throws {
        try await withFile { url in
            do {
                let db = try BocchiDB(url: url)
                try await db.put(id: "a", body: ["type": "x"])
                try await db.createIndex(fields: ["type"])
            }
            do {
                let reader = try BocchiDB(url: url, mode: .readOnly)
                #expect(try await reader.find(FindQuery(selector: ["type": "x"])).map(\.id) == ["a"])
                #expect(await reader.lastFindIndex != nil)
                await #expect(throws: BocchiDBError.readOnly) { try await reader.createIndex(fields: ["n"]) }
                await #expect(throws: BocchiDBError.readOnly) { try await reader.deleteIndex(name: "x") }
                await #expect(throws: BocchiDBError.readOnly) { try await reader.setDesignIndexesEnabled(true) }
            }
            // 索引に反映されていない書き込みがあると、読み取り専用では索引を使わずに全件を読む。
            do {
                let writer = try BocchiDB(url: url)
                try await writer.put(id: "b", body: ["type": "x"])
            }
            let reader = try BocchiDB(url: url, mode: .readOnly)
            #expect(try await reader.find(FindQuery(selector: ["type": "x"])).map(\.id) == ["a", "b"])
            #expect(await reader.lastFindIndex == nil)
        }
    }

    @Test func readOnlyOpensFileWithoutIndexTables() async throws {
        try await withFile { url in
            do {
                let db = try BocchiDB(url: url)
                try await db.put(id: "a", body: ["type": "x"])
            }
            // 0.0.4 以前に作られたファイルを再現する。
            try SQLiteConnection(path: url.path).execute("DROP TABLE index_entries; DROP TABLE indexes;")

            let reader = try BocchiDB(url: url, mode: .readOnly)
            #expect(try await reader.indexes() == [])
            #expect(try await reader.find(FindQuery(selector: ["type": "x"])).map(\.id) == ["a"])
        }
    }
}
