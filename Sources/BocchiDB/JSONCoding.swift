import Foundation

extension JSONValue {
    /// 入れ子の深さの上限。読み書きや比較を再帰で行うため、スタックがあふれないように制限する。
    public static let maxDepth = 128

    /// JSON を読む。オブジェクトのキーは記述順を保つ。同じキーが複数あれば最後の値を使う。
    /// 入れ子が `maxDepth` より深いものは `BocchiDBError.invalidJSON` になる。
    ///
    /// 数値は、小数点も指数もなく `Int64` に収まるものを `.int`、それ以外を `.double` にする。
    public init(json: Data) throws {
        self = try json.withUnsafeBytes { buffer in
            var parser = JSONParser(bytes: buffer.bindMemory(to: UInt8.self))
            return try parser.parseDocument()
        }
    }

    /// 空白なしの JSON にする。オブジェクトのキーは記述順のまま、`/` はエスケープしない。
    /// 有限でない小数（NaN、無限大）と、入れ子が `maxDepth` より深い値は `BocchiDBError.invalidJSON` になる。
    public func jsonData() throws -> Data {
        var output: [UInt8] = []
        try JSONWriter.write(self, depth: 0, into: &output)
        return Data(output)
    }
}

private struct JSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0
    var depth = 0

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSONValue {
        let value = try parseValue()
        skipWhitespace()
        guard position == bytes.count else { throw error("unexpected data after the value") }
        return value
    }

    private func error(_ message: String) -> BocchiDBError {
        .invalidJSON("\(message) at byte \(position)")
    }

    private mutating func skipWhitespace() {
        while position < bytes.count {
            switch bytes[position] {
            case 0x20, 0x09, 0x0A, 0x0D: position += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        skipWhitespace()
        guard position < bytes.count else { throw error("unexpected end of data") }
        switch bytes[position] {
        case UInt8(ascii: "{"): return .object(try parseObject())
        case UInt8(ascii: "["): return .array(try parseArray())
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    private mutating func expectLiteral(_ literal: StaticString) throws {
        let count = literal.utf8CodeUnitCount
        guard position + count <= bytes.count,
              (0..<count).allSatisfy({ bytes[position + $0] == literal.utf8Start[$0] })
        else { throw error("invalid literal") }
        position += count
    }

    private mutating func enterContainer() throws {
        depth += 1
        guard depth <= JSONValue.maxDepth else { throw error("too deeply nested") }
        position += 1
    }

    private mutating func parseObject() throws -> JSONObject {
        try enterContainer()
        defer { depth -= 1 }
        var object = JSONObject()
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "}") {
            position += 1
            return object
        }
        while true {
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: "\"") else { throw error("expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard position < bytes.count, bytes[position] == UInt8(ascii: ":") else { throw error("expected ':'") }
            position += 1
            object[key] = try parseValue()
            skipWhitespace()
            guard position < bytes.count else { throw error("unexpected end of data") }
            switch bytes[position] {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"): position += 1; return object
            default: throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> [JSONValue] {
        try enterContainer()
        defer { depth -= 1 }
        var array: [JSONValue] = []
        skipWhitespace()
        if position < bytes.count, bytes[position] == UInt8(ascii: "]") {
            position += 1
            return array
        }
        while true {
            array.append(try parseValue())
            skipWhitespace()
            guard position < bytes.count else { throw error("unexpected end of data") }
            switch bytes[position] {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"): position += 1; return array
            default: throw error("expected ',' or ']'")
            }
        }
    }

    private mutating func parseString() throws -> String {
        position += 1  // 開始の "
        let start = position
        // エスケープがなければ、そのまま切り出す。
        while position < bytes.count {
            let byte = bytes[position]
            if byte == UInt8(ascii: "\"") {
                defer { position += 1 }
                return try makeString(UnsafeBufferPointer(rebasing: bytes[start..<position]))
            }
            if byte == UInt8(ascii: "\\") { break }
            if byte < 0x20 { throw error("control character in string") }
            position += 1
        }
        var scalars = Array(bytes[start..<position])
        while position < bytes.count {
            let byte = bytes[position]
            switch byte {
            case UInt8(ascii: "\""):
                position += 1
                return try scalars.withUnsafeBufferPointer(makeString)
            case UInt8(ascii: "\\"):
                position += 1
                try appendEscape(to: &scalars)
            case ..<0x20:
                throw error("control character in string")
            default:
                scalars.append(byte)
                position += 1
            }
        }
        throw error("unterminated string")
    }

    private func makeString(_ utf8: UnsafeBufferPointer<UInt8>) throws -> String {
        // 不正なバイトは U+FFFD に置き換わり、元のバイト列と一致しなくなる。
        let string = String(decoding: utf8, as: UTF8.self)
        guard string.utf8.elementsEqual(utf8) else { throw error("invalid UTF-8") }
        return string
    }

    private mutating func appendEscape(to output: inout [UInt8]) throws {
        guard position < bytes.count else { throw error("unterminated string") }
        let byte = bytes[position]
        position += 1
        switch byte {
        case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): output.append(byte)
        case UInt8(ascii: "b"): output.append(0x08)
        case UInt8(ascii: "f"): output.append(0x0C)
        case UInt8(ascii: "n"): output.append(0x0A)
        case UInt8(ascii: "r"): output.append(0x0D)
        case UInt8(ascii: "t"): output.append(0x09)
        case UInt8(ascii: "u"):
            var code = try parseHex4()
            if (0xD800..<0xDC00).contains(code) {
                guard position + 1 < bytes.count, bytes[position] == UInt8(ascii: "\\"),
                      bytes[position + 1] == UInt8(ascii: "u") else { throw error("unpaired surrogate") }
                position += 2
                let low = try parseHex4()
                guard (0xDC00..<0xE000).contains(low) else { throw error("unpaired surrogate") }
                code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
            } else if (0xDC00..<0xE000).contains(code) {
                throw error("unpaired surrogate")
            }
            output.append(contentsOf: String(Character(Unicode.Scalar(code)!)).utf8)
        default:
            throw error("invalid escape")
        }
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw error("invalid \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[position]
            let digit: UInt8 = switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
            default: throw error("invalid \\u escape")
            }
            value = value << 4 | UInt32(digit)
            position += 1
        }
        return value
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = position
        var isInteger = true
        if bytes[position] == UInt8(ascii: "-") { position += 1 }
        guard position < bytes.count, isDigit(bytes[position]) else { throw error("invalid number") }
        if bytes[position] == UInt8(ascii: "0") {
            position += 1
        } else {
            skipDigits()
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: ".") {
            isInteger = false
            position += 1
            guard position < bytes.count, isDigit(bytes[position]) else { throw error("invalid number") }
            skipDigits()
        }
        if position < bytes.count, bytes[position] == UInt8(ascii: "e") || bytes[position] == UInt8(ascii: "E") {
            isInteger = false
            position += 1
            if position < bytes.count, bytes[position] == UInt8(ascii: "+") || bytes[position] == UInt8(ascii: "-") {
                position += 1
            }
            guard position < bytes.count, isDigit(bytes[position]) else { throw error("invalid number") }
            skipDigits()
        }
        let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<position]), as: UTF8.self)
        if isInteger, let value = Int64(text) { return .int(value) }
        guard let value = Double(text), value.isFinite else { throw error("number out of range") }
        return .double(value)
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }

    private mutating func skipDigits() {
        while position < bytes.count, isDigit(bytes[position]) { position += 1 }
    }
}

private enum JSONWriter {
    static func write(_ value: JSONValue, depth: Int, into output: inout [UInt8]) throws {
        switch value {
        case .null:
            output.append(contentsOf: "null".utf8)
        case .bool(let bool):
            output.append(contentsOf: (bool ? "true" : "false").utf8)
        case .int(let int):
            output.append(contentsOf: String(int).utf8)
        case .double(let double):
            // description は "25.5"、"5.0"、"1e-05" のように JSON として正しい形になる。
            guard double.isFinite else { throw BocchiDBError.invalidJSON("non-finite number \(double)") }
            output.append(contentsOf: double.description.utf8)
        case .string(let string):
            writeString(string, into: &output)
        case .array(let array):
            guard depth < JSONValue.maxDepth else { throw BocchiDBError.invalidJSON("too deeply nested") }
            output.append(UInt8(ascii: "["))
            for (index, element) in array.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                try write(element, depth: depth + 1, into: &output)
            }
            output.append(UInt8(ascii: "]"))
        case .object(let object):
            guard depth < JSONValue.maxDepth else { throw BocchiDBError.invalidJSON("too deeply nested") }
            output.append(UInt8(ascii: "{"))
            for (index, (key, element)) in object.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                writeString(key, into: &output)
                output.append(UInt8(ascii: ":"))
                try write(element, depth: depth + 1, into: &output)
            }
            output.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeString(_ string: String, into output: inout [UInt8]) {
        output.append(UInt8(ascii: "\""))
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "\""): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case UInt8(ascii: "\\"): output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x08: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
            case 0x0C: output.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
            case ..<0x20:
                output.append(contentsOf: "\\u00".utf8)
                output.append(hexDigits[Int(byte >> 4)])
                output.append(hexDigits[Int(byte & 0x0F)])
            default:
                output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }
}
