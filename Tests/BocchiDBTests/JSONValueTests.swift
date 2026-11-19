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

    @Test func roundTripsThroughEncoder() throws {
        let json = #"{"a":[1,2.5,"x",null,true],"b":{"c":"/path"}}"#
        #expect(try encode(decode(json)) == json)
    }
}
