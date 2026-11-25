import Foundation
import Testing
@testable import BocchiDB

@Suite struct JSONValueTests {
    private func decode(_ json: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    private func encode(_ value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test func decodesAllKinds() throws {
        let value = try decode(#"{"n":null,"b":true,"i":27,"d":25.5,"s":"温度","a":[1,"x"],"o":{"k":false}}"#)
        let expected: JSONValue = [
            "n": nil, "b": true, "i": 27, "d": 25.5, "s": "温度",
            "a": [1, "x"], "o": ["k": false],
        ]
        #expect(value == expected)
    }

    /// JSONSerialization（NSNumber）では true と 1 が区別できなくなることがあるため、明示的に確認する。
    @Test func keepsBoolAndNumberDistinct() throws {
        #expect(try decode("[true, 1, false, 0]") == .array([.bool(true), .int(1), .bool(false), .int(0)]))
    }

    @Test func keepsIntegerAndFractionDistinct() throws {
        #expect(try decode("[27, 25.5, -3, 1e-3]") == .array([.int(27), .double(25.5), .int(-3), .double(0.001)]))
    }

    /// 2^53 を超える整数も Int64 の範囲なら失わない。
    @Test func keepsLargeIntegers() throws {
        #expect(try decode("9007199254740993") == .int(9_007_199_254_740_993))
    }

    /// JSON では 26 と 26.0 は同じ数。別の端末を経由すると整数として届くため、等しく扱う必要がある。
    @Test func comparesNumbersByValue() throws {
        #expect(JSONValue.int(26) == .double(26.0))
        #expect(JSONValue.double(26.0).hashValue == JSONValue.int(26).hashValue)
        #expect(JSONValue.int(26) != .double(26.5))
        #expect(JSONValue.int(9_007_199_254_740_993) != .double(9_007_199_254_740_992))
        #expect(try decode(#"{"t":26}"#) == ["t": 26.0])
        #expect(JSONValue.bool(true) != .int(1))
    }

    // MARK: - JSONValue(json:) と jsonData()

    private func parse(_ json: String) throws -> JSONValue {
        try JSONValue(json: Data(json.utf8))
    }

    private func write(_ value: JSONValue) throws -> String {
        String(decoding: try value.jsonData(), as: UTF8.self)
    }

    @Test func parserKeepsKeyOrder() throws {
        let json = #"{"z":1,"a":{"y":true,"b":null},"m":[{"k":"v","c":2.5}]}"#
        let value = try parse(json)
        guard case .object(let object) = value, case .object(let nested)? = object["a"] else {
            Issue.record("not an object"); return
        }
        #expect(object.keys == ["z", "a", "m"])
        #expect(nested.keys == ["y", "b"])
        #expect(try write(value) == json)
    }

    /// 小数点も指数もなく Int64 に収まる数だけを整数にする。
    @Test func parserDistinguishesIntegersAndDoubles() throws {
        let value = try parse("[true, 1, false, 0, 27, 25.5, -3, 1e-3, 1E2, -0, 9007199254740993, 99999999999999999999, 2.0]")
        let expected: [String] = ["bool", "int", "bool", "int", "int", "double", "int", "double",
                                  "double", "int", "int", "double", "double"]
        guard case .array(let items) = value else { Issue.record("not an array"); return }
        #expect(items.map { item -> String in
            switch item {
            case .bool: "bool"
            case .int: "int"
            case .double: "double"
            default: "other"
            }
        } == expected)
        #expect(value == [true, 1, false, 0, 27, 25.5, -3, 0.001, 100, 0, 9_007_199_254_740_993, 1e20, 2])
        #expect(throws: BocchiDBError.self) { try parse("1e400") }
    }

    @Test func parserHandlesStringEscapes() throws {
        #expect(try parse(#""a\"b\\c\/d\n\t\u00e9\ud83d\ude00""#) == .string("a\"b\\c/d\n\té😀"))
        #expect(try parse(#""温度 ok""#) == .string("温度 ok"))
    }

    @Test(arguments: [
        "", "{", "[1,]", "{\"a\"}", "{\"a\":1,}", "01", "1.", "-", "tru", "nul", "\"abc", "\"\\x\"",
        "\"\\ud83d\"", "\"\\ude00\"", "\"a\nb\"", "[1] 2", "{'a':1}", "NaN",
    ])
    func parserRejectsInvalidJSON(_ json: String) {
        #expect(throws: BocchiDBError.self) { try parse(json) }
    }

    @Test func parserRejectsInvalidUTF8AndDeepNesting() {
        #expect(throws: BocchiDBError.self) { try JSONValue(json: Data([0x22, 0xFF, 0x22])) }
        let limit = JSONValue.maxDepth
        #expect((try? parse(String(repeating: "[", count: limit) + String(repeating: "]", count: limit))) != nil)
        #expect(throws: BocchiDBError.self) { try parse(String(repeating: "[", count: limit + 1) + String(repeating: "]", count: limit + 1)) }
        // 書き込みも同じ深さで止める（put で深すぎる本文を渡した場合など）。
        var deep: JSONValue = 1
        for _ in 0..<limit { deep = [deep] }
        #expect((try? deep.jsonData()) != nil)
        #expect(throws: BocchiDBError.self) { try JSONValue.array([deep]).jsonData() }
    }

    @Test func parserUsesLastValueForDuplicateKeys() throws {
        guard case .object(let object) = try parse(#"{"a":1,"b":2,"a":3}"#) else { Issue.record("not an object"); return }
        #expect(object.keys == ["a", "b"])
        #expect(object["a"] == 3)
    }

    @Test func writerEscapesAndFormats() throws {
        #expect(try write(["s": "a\"b\\c/d\n\u{1}é", "d": 5.0, "e": 1e-5, "i": -2, "n": nil, "b": false, "a": []])
            == #"{"s":"a\"b\\c/d\n\u0001é","d":5.0,"e":1e-05,"i":-2,"n":null,"b":false,"a":[]}"#)
        #expect(throws: BocchiDBError.self) { try JSONValue.double(.nan).jsonData() }
        #expect(throws: BocchiDBError.self) { try JSONValue.array([.double(.infinity)]).jsonData() }
    }

    /// ランダムな値で、書いて読み直すと同じ値・同じキー順に戻ることを確かめる。
    @Test func writerAndParserRoundTrip() throws {
        var random = SeededRandom(seed: 7)
        func makeValue(_ depth: Int) -> JSONValue {
            switch random.next() % (depth > 3 ? 5 : 7) {
            case 0: return .null
            case 1: return .bool(random.next() % 2 == 0)
            case 2: return .int(Int64(bitPattern: random.next()))
            case 3: return .double(Double(Int64(bitPattern: random.next() >> 11)) / 1024)
            case 4: return .string(String((0..<random.next() % 6).map { _ in
                ["a", "\"", "\\", "\n", "\u{0}", "é", "😀", "温"][Int(random.next() % 8)] }.joined()))
            case 5: return .array((0..<random.next() % 4).map { _ in makeValue(depth + 1) })
            default: return .object(JSONObject((0..<random.next() % 4).map { i in ("k\(random.next() % 10)", makeValue(depth + 1)) }))
            }
        }
        for _ in 0..<500 {
            let value = makeValue(0)
            let data = try value.jsonData()
            let parsed = try JSONValue(json: data)
            #expect(parsed == value)
            #expect(try parsed.jsonData() == data)
        }
    }

    // MARK: - JSONObject

    @Test func objectKeepsInsertionOrderAndComparesWithoutOrder() {
        var object: JSONObject = ["b": 1, "a": 2]
        object["c"] = 3
        object["b"] = 4
        #expect(object.keys == ["b", "a", "c"])
        #expect(object["b"] == 4)
        object["a"] = nil
        #expect(object.keys == ["b", "c"])
        #expect(object.removeValue(forKey: "b") == 4)
        #expect(object.map(\.key) == ["c"])

        let xy: JSONObject = ["x": 1, "y": 2]
        let yx: JSONObject = ["y": 2, "x": 1]
        #expect(xy == yx)
        #expect(xy.hashValue == yx.hashValue)
        #expect(xy.filter { key, _ in key == "y" }.keys == ["y"])
        #expect(JSONObject(["b": 1, "a": 2]).keys == ["a", "b"])
    }

    @Test func roundTripsThroughEncoder() throws {
        let json = #"{"a":[1,2.5,"x",null,true],"b":{"c":"/path"}}"#
        #expect(try encode(decode(json)) == json)
    }
}
