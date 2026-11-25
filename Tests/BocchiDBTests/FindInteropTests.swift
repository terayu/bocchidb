import Foundation
import Testing
@testable import BocchiDB

/// 同じ文書とクエリで、`BocchiDB.find` と CouchDB の `_find` の結果が一致することを確かめる。
/// 環境変数 `BOCCHIDB_COUCHDB_URL` がないときはスキップする。
@Suite(.enabled(if: CouchServer.baseURL != nil), .serialized)
struct FindInteropTests {
    private static let fixtures: [String: JSONObject] = [
        "n-int": ["v": 1, "type": "num", "n": 10],
        "n-dbl": ["v": 2.5, "type": "num", "n": 3],
        "n-neg": ["v": -7, "type": "num", "n": -4],
        "n-big": ["v": 100, "type": "num"],
        "s-a": ["v": "a", "type": "str"],
        "s-A": ["v": "A", "type": "str"],
        "s-b": ["v": "b", "type": "str"],
        "s-B": ["v": "B", "type": "str"],
        "s-empty": ["v": "", "type": "str"],
        "s-10": ["v": "10", "type": "str"],
        "s-9": ["v": "9", "type": "str"],
        "s-e": ["v": "e", "type": "str"],
        "s-e-acute": ["v": "\u{e9}", "type": "str"],
        "s-e-combining": ["v": "e\u{301}", "type": "str"],
        "s-hiragana": ["v": "あ", "type": "str"],
        "s-katakana": ["v": "ア", "type": "str"],
        "s-halfwidth": ["v": "ｱ", "type": "str"],
        "s-i": ["v": "い", "type": "str"],
        "s-kanji": ["v": "亜", "type": "str"],
        "s-space": ["v": "a b", "type": "str"],
        "s-hyphen": ["v": "a-b", "type": "str"],
        "null": ["v": nil, "type": "other"],
        "true": ["v": true, "type": "other"],
        "false": ["v": false, "type": "other"],
        "arr": ["v": [1, 2], "type": "other", "tags": ["x", "y"]],
        "arr-empty": ["v": [], "type": "other", "tags": []],
        "arr-nested": ["v": [[1, 2], 3], "type": "other", "tags": ["y"]],
        "obj": ["v": ["x": 1], "type": "other", "user": ["name": "ruth", "age": 30, "langs": ["ja", "en"]]],
        "obj2": ["type": "other", "user": ["name": "Rin", "age": 25]],
        "no-v": ["w": 1],
        "Z-upper-id": ["v": 3, "type": "num"],
        "é-id": ["v": 4, "type": "num"],
        "あ-id": ["v": 5, "type": "num"],
        "dotted": ["a.b": 1, "a": ["b": 2]],
        // CouchDB はオブジェクトをキーの記述順に比べるので、同じ内容でもキーの順序が違えば別の値になる。
        "o-xy": ["v": ["x": 1, "y": 2], "type": "obj"],
        "o-yx": ["v": ["y": 2, "x": 1], "type": "obj"],
        "o-x2": ["v": ["x": 2], "type": "obj"],
        "o-ba": ["v": ["b": 1, "a": 9], "type": "obj"],
    ]

    /// [クエリの JSON]。`limit` がないものは CouchDB の既定（25 件）を避けるため、比較時に大きな値を補う。
    private static let queries: [String] = [
        // 等価と入れ子
        #"{"selector": {"v": 1}}"#,
        #"{"selector": {"v": 1.0}}"#,
        #"{"selector": {"v": null}}"#,
        #"{"selector": {"v": [1, 2]}}"#,
        #"{"selector": {"v": {"x": 1}}}"#,
        #"{"selector": {"user": {"name": "ruth"}}}"#,
        #"{"selector": {"user.name": "ruth"}}"#,
        #"{"selector": {"user.langs.0": "ja"}}"#,
        #"{"selector": {"a\\.b": 1}}"#,
        #"{"selector": {"a.b": 2}}"#,
        #"{"selector": {"v": "é"}}"#,
        // オブジェクトの比較（キーの記述順）
        #"{"selector": {"v": {"$eq": {"x": 1, "y": 2}}}}"#,
        #"{"selector": {"v": {"$eq": {"y": 2, "x": 1}}}}"#,
        #"{"selector": {"v": {"$gt": {"x": 1}}}}"#,
        #"{"selector": {"v": {"$lt": {"b": 5}}}}"#,
        #"{"selector": {"v": {"$in": [{"y": 2, "x": 1}]}}}"#,
        #"{"selector": {"v": {"$ne": {"x": 1, "y": 2}}, "type": "obj"}}"#,
        // 比較（型をまたぐ）
        #"{"selector": {"v": {"$gt": 2}}}"#,
        #"{"selector": {"v": {"$gte": "a", "$lt": "b"}}}"#,
        #"{"selector": {"v": {"$lt": "a"}}}"#,
        #"{"selector": {"v": {"$lte": null}}}"#,
        #"{"selector": {"v": {"$gt": [1]}}}"#,
        #"{"selector": {"v": {"$gt": "ア"}}}"#,
        #"{"selector": {"_id": {"$gt": "Z"}}}"#,
        #"{"selector": {"_id": {"$lt": "a"}}}"#,
        #"{"selector": {"_id": {"$gt": null}}}"#,
        // 否定とフィールドがない場合
        #"{"selector": {"v": {"$ne": 1}}}"#,
        #"{"selector": {"$not": {"v": 1}}}"#,
        #"{"selector": {"$nor": [{"v": 1}, {"type": "str"}]}}"#,
        #"{"selector": {"v": {"$not": {"$gt": 2}}}}"#,
        #"{"selector": {"v": {"$exists": false}}}"#,
        #"{"selector": {"$not": {"v": {"$exists": true}}}}"#,
        #"{"selector": {"$not": {"v": {"$exists": false}}}}"#,
        #"{"selector": {"$not": {"$or": [{"type": "num"}, {"type": "str"}]}}}"#,
        #"{"selector": {"$not": {"$and": [{"type": "num"}, {"v": {"$gt": 2}}]}}}"#,
        // 論理演算
        #"{"selector": {"$or": [{"v": 1}, {"v": "a"}, {"user.age": {"$lt": 28}}]}}"#,
        #"{"selector": {"$and": [{"type": "num"}, {"v": {"$gt": 1}}]}}"#,
        #"{"selector": {"type": {"$or": [{"$eq": "num"}, {"$eq": "other"}]}}}"#,
        // 配列
        #"{"selector": {"v": {"$in": [2, "a", null]}}}"#,
        #"{"selector": {"v": {"$in": [[1, 2]]}}}"#,
        #"{"selector": {"tags": {"$in": [["x", "y"]]}}}"#,
        #"{"selector": {"tags": {"$nin": ["x"]}}}"#,
        #"{"selector": {"v": {"$nin": [1, "a"]}}}"#,
        #"{"selector": {"tags": {"$all": ["x", "y"]}}}"#,
        #"{"selector": {"v": {"$all": [[1, 2]]}}}"#,
        #"{"selector": {"tags": {"$all": []}}}"#,
        #"{"selector": {"tags": {"$size": 0}}}"#,
        #"{"selector": {"v": {"$elemMatch": {"$gt": 1}}}}"#,
        #"{"selector": {"v": {"$allMatch": {"$gte": 1}}}}"#,
        #"{"selector": {"tags": {"$allMatch": {"$eq": "y"}}}}"#,
        // そのほかの演算子
        #"{"selector": {"v": {"$type": "number"}}}"#,
        #"{"selector": {"v": {"$type": "array"}}}"#,
        #"{"selector": {"n": {"$mod": [3, 1]}}}"#,
        #"{"selector": {"n": {"$mod": [3, -1]}}}"#,
        #"{"selector": {"v": {"$regex": "^[a-b]"}}}"#,
        #"{"selector": {"user.name": {"$regex": "(?i)^r"}}}"#,
        #"{"selector": {"v": {"$beginsWith": "a"}}}"#,
        // 並べ替え・件数・フィールド
        #"{"selector": {"type": "str"}, "sort": ["v"]}"#,
        #"{"selector": {"type": "obj"}, "sort": ["v"]}"#,
        #"{"selector": {"v": {"$exists": true}}, "sort": [{"v": "desc"}]}"#,
        #"{"selector": {"_id": {"$gt": null}}, "sort": ["v"]}"#,
        #"{"selector": {"type": {"$gt": null}}, "sort": ["type", "v"]}"#,
        #"{"selector": {"type": "num"}, "sort": ["v"], "skip": 1, "limit": 3}"#,
        #"{"selector": {"type": "str"}, "limit": 4, "skip": 2}"#,
        #"{"selector": {"type": "other"}, "fields": ["_id", "user.name", "tags", "missing"]}"#,
        #"{"selector": {"user": {"$exists": true}}, "fields": ["_id", "user.age", "user.name"]}"#,
    ]

    /// 並べ替えに使う索引（CouchDB は索引がないと sort できない）。
    ///
    /// CouchDB 3.5.3 は JSON の索引が 1 つでもあると、$in や $all に null や配列を渡したクエリが 500 になる。
    /// そのため、sort のないクエリは索引を作る前に実行する。
    private static let indexes: [[String]] = [["v"], ["type", "v"]]

    /// CouchDB で作った索引が同期で届き、端末側でも同じ索引が使われる。CouchDB で消すと端末側も消える。
    @Test func indexesFollowCouchDBDesignDocuments() async throws {
        try await CouchServer.withDatabase { couch in
            try await couch.bulkDocs((0..<20).map { ["_id": .string("d\($0)"), "type": "x", "n": .int(Int64($0))] })
            try await couch.createIndex(fields: ["type", "n"], ddoc: "inspections", name: "by-type-n")

            let db = try BocchiDB(path: ":memory:")
            try await db.setDesignIndexesEnabled(true)
            try await couch.replicator(for: db).pull()
            let query = FindQuery(selector: ["type": "x", "n": ["$gte": 18]])
            #expect(try await db.find(query).map(\.id) == ["d18", "d19"])
            #expect(await db.lastFindIndex == "_design/inspections/by-type-n")

            try await couch.deleteIndex(ddoc: "inspections", name: "by-type-n")
            try await couch.replicator(for: db).pull()
            #expect(try await db.find(query).map(\.id) == ["d18", "d19"])
            #expect(await db.lastFindIndex == nil)
            #expect(try await db.indexes() == [])
        }
    }

    @Test func findMatchesCouchDB() async throws {
        try await CouchServer.withDatabase { couch in
            let db = try BocchiDB(path: ":memory:")
            for (id, body) in Self.fixtures { try await db.put(id: id, body: body) }
            try await db.put(id: "_design/ignored", body: ["v": 1, "type": "num"])
            let deletedRev = try await db.put(id: "deleted", body: ["v": 1, "type": "num"])
            try await db.remove(id: "deleted", rev: deletedRev)

            try await couch.bulkDocs(Self.fixtures.map { id, body in var doc = body; doc["_id"] = .string(id); return doc }
                                     + [["_id": "_design/ignored", "v": 1, "type": "num"]])

            // bocchidb 側は索引を作った状態で比べる（索引の有無で結果が変わらないことは IndexTests で確認）。
            for fields in Self.indexes + [["tags"], ["user.name"], ["n"], ["_id"]] {
                try await db.createIndex(fields: fields)
            }

            let parsed = try Self.queries.map { ($0, try FindQuery(json: Data($0.utf8))) }
            let ordered = parsed.filter { $0.1.sort.isEmpty } + parsed.filter { !$0.1.sort.isEmpty }
            var indexesCreated = false
            var indexedQueries = 0
            for (json, query) in ordered {
                if !query.sort.isEmpty, !indexesCreated {
                    for fields in Self.indexes { try await couch.createIndex(fields: fields) }
                    indexesCreated = true
                }
                let local = try await db.find(query)
                if await db.lastFindIndex != nil { indexedQueries += 1 }

                guard case .object(var couchQuery) = try JSONValue(json: Data(json.utf8)) else { continue }
                if couchQuery["limit"] == nil { couchQuery["limit"] = 10_000 }
                let remote: [JSONObject]
                do {
                    remote = try await couch.find(try JSONValue.object(couchQuery).jsonData())
                } catch {
                    Issue.record("\(json): \(error)")
                    continue
                }

                // sort がないとき、CouchDB の並び順は使った索引で変わる（v の索引を使えば v の順）ため、集合として比べる。
                let reserved: Set<String> = ["_id", "_rev", "_attachments"]
                var localResults = local.map { (id: $0.id, body: $0.body) }
                var remoteResults = remote.map { doc in
                    (id: doc["_id"].flatMap { if case .string(let id) = $0 { id } else { nil } } ?? "?",
                     body: doc.filter { key, _ in !reserved.contains(key) })
                }
                if query.sort.isEmpty {
                    localResults.sort { $0.id < $1.id }
                    remoteResults.sort { $0.id < $1.id }
                }
                #expect(localResults.map(\.id) == remoteResults.map(\.id), "\(json)")
                if query.fields != nil {
                    #expect(localResults.map(\.body) == remoteResults.map(\.body), "\(json)")
                }
            }
            #expect(indexedQueries > Self.queries.count / 2, "索引を使ったクエリが少なすぎる（\(indexedQueries) 件）")
        }
    }
}
