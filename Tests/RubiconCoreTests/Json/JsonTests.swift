import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("Json writing")
struct JsonWritingTests {
    private func assertSameJson(_ expected: String, _ actual: String, _ location: SourceLocation = #_sourceLocation)
        throws
    {
        #expect(try JSONValue.parse(expected) == JSONValue.parse(actual), sourceLocation: location)
    }

    @Test("writes null as JSON null, also nested")
    func nulls() throws {
        #expect(try Json.write(["coupon": .null]) == #"{"coupon":null}"#)
        try assertSameJson(
            #"{"a":{"b":null},"c":[1,null]}"#,
            try Json.write(["a": .object(["b": .null]), "c": .array([.int(1), .null])]))
    }

    @Test("writes every value type, compact, with sorted keys")
    func everyType() throws {
        let line = try Json.write([
            "s": .string("text"), "t": .bool(true), "f": .bool(false), "i": .int(7),
            "l": .int(9_007_199_254_740_993), "d": .double(1.5), "n": .null,
            "list": .array([
                .string("a"), .int(1), .double(2.5), .bool(false), .null, .array([.int(1)]),
                .object(["k": .string("v")]),
            ]),
            "map": .object(["nested": .object(["deep": .array([.int(1), .int(2)])])]),
        ])

        try assertSameJson(
            #"{"s":"text","t":true,"f":false,"i":7,"l":9007199254740993,"d":1.5,"n":null,"#
                + #""list":["a",1,2.5,false,null,[1],{"k":"v"}],"map":{"nested":{"deep":[1,2]}}}"#, line)
        #expect(!line.contains { $0.isWhitespace })
        #expect(line.hasPrefix(#"{"d":1.5,"f":false,"i":7,"#))
    }

    @Test("writes an empty object, array and string")
    func empties() throws {
        try assertSameJson(
            #"{"m":{},"l":[],"s":""}"#, try Json.write(["m": .object([:]), "l": .array([]), "s": .string("")]))
    }

    @Test("refuses NaN and infinity, naming the path", arguments: [Double.nan, .infinity, -.infinity])
    func notFinite(value: Double) {
        #expect(throws: JsonError.notFinite(path: "x")) { try Json.write(["x": .double(value)]) }
        #expect(throws: JsonError.notFinite(path: "x[0]")) { try Json.write(["x": .array([.double(value)])]) }
        #expect(throws: JsonError.notFinite(path: "a.b")) { try Json.write(["a": .object(["b": .double(value)])]) }
    }

    @Test("true and 1 stay apart")
    func boolsAndNumbers() throws {
        #expect(try Json.write(["b": .bool(true), "i": .int(1)]) == #"{"b":true,"i":1}"#)
    }
}

// Each JSONSerialization behaviour the SDK relies on or documents; a Foundation change fails here.
@Suite("JSONSerialization behaviours")
struct JsonBehaviourTests {
    @Test("a whole-number double is written as an integer")
    func wholeDouble() throws {
        #expect(try Json.write(["price": .double(50)]) == #"{"price":50}"#)
    }

    @Test("a slash is escaped")
    func slash() throws {
        let line = try Json.write(["url": .string("https://a.com/b")])
        #expect(line == #"{"url":"https:\/\/a.com\/b"}"#)
        #expect(try JSONValue.parse(line) == .object(["url": .string("https://a.com/b")]))
    }

    @Test("a non-integral double carries seventeen significant digits, unlike Android")
    func seventeenDigits() throws {
        #expect(try Json.write(["x": .double(49.9)]) == #"{"x":49.899999999999999}"#)
        #expect(try Json.write(["x": .double(9.99)]) == #"{"x":9.9900000000000002}"#)
        #expect(try JSONValue.parse(try Json.write(["x": .double(49.9)])) == .object(["x": .number(49.9)]))
    }

    @Test("very large and small doubles use exponent form")
    func exponents() throws {
        let line = try Json.write(["x": .double(1e21), "y": .double(1.5e-7)])
        #expect(line == #"{"x":1e+21,"y":1.4999999999999999e-07}"#)
        _ = try JSONValue.parse(line)
    }

    @Test("JSONSerialization refuses NaN, which is why the writer checks first")
    func nanRefused() {
        #expect(!JSONSerialization.isValidJSONObject(["x": Double.nan]))
    }

    @Test("a boolean read back is a CFBoolean and a 1 is not")
    func booleanDetection() throws {
        let fields = try #require(Json.readObject(#"{"b":true,"i":1,"z":0,"f":false}"#))
        #expect(fields.bool("b") == true)
        #expect(fields.bool("f") == false)
        #expect(fields.bool("i") == nil)
        #expect(fields.int64("b") == nil)
        #expect(fields.int64("i") == 1)
        #expect(fields.double("z") == 0)
        #expect(fields.double("b") == nil)
    }
}

@Suite("Json round trip")
struct JsonRoundTripTests {
    @Test("every value type comes back")
    func everyType() throws {
        let object: [String: PropertyValue] = [
            "s": .string("text"), "b": .bool(true), "i": .int(7), "l": .int(9_007_199_254_740_993), "d": .double(1.5),
            "n": .null, "list": .array([.string("a"), .int(1), .null, .array([.bool(true)])]),
            "map": .object(["k": .object(["deep": .string("v")])]),
        ]
        let back = try #require(Json.readObject(try Json.write(object)))
        #expect(back.toPropertyValues() == object)
    }

    @Test("a whole double comes back as an int, a fraction as a double")
    func numbersBack() throws {
        let back = try #require(
            Json.readObject(
                try Json.write([
                    "small": .int(7), "whole": .double(50), "big": .int(5_000_000_000), "frac": .double(0.5),
                ])))
        #expect(
            back.toPropertyValues() == [
                "small": .int(7), "whole": .int(50), "big": .int(5_000_000_000), "frac": .double(0.5),
            ])
    }

    @Test("non-ASCII, escaped and control characters survive, and a line never contains a raw line break")
    func hostileCharacters() throws {
        let text = "ğüşİıöç 日本 😀 \"quoted\" back\\slash /slash \n\t\r\u{8}\u{c} \u{1} \u{2028} \u{2029}"
        let line = try Json.write([text: .string(text)])

        #expect(try #require(Json.readObject(line)).toPropertyValues() == [text: .string(text)])
        #expect(try JSONValue.parse(line) == .object([text: .string(text)]))
        #expect(!line.contains("\n"))
    }

    @Test("a 32 KB line survives")
    func bigLine() throws {
        let value = String(repeating: "x", count: 32 * 1024)
        let line = try Json.write(["big": .string(value)])
        #expect(line.count > 32 * 1024)
        #expect(try #require(Json.readObject(line)).string("big") == value)
        _ = try JSONValue.parse(line)
    }

    @Test("seeded random trees are valid JSON to the independent parser and read back the same")
    func randomTrees() throws {
        let random = SeededRandom(seed: 7)
        for _ in 0..<2_000 {
            let object = Self.randomObject(random, depth: 0)
            let line = try Json.write(object)
            #expect(try JSONValue.parse(line) == JSONValue(.object(object)), Comment(rawValue: line))
            let back = try #require(Json.readObject(line)).toPropertyValues()
            #expect(JSONValue(.object(back)) == JSONValue(.object(object)), Comment(rawValue: line))
        }
    }

    static func randomObject(_ random: SeededRandom, depth: Int) -> [String: PropertyValue] {
        var object: [String: PropertyValue] = [:]
        for _ in 0..<Int(random.nextUInt64() % 6) {
            object[randomString(random)] = randomValue(random, depth: depth)
        }
        return object
    }

    static func randomValue(_ random: SeededRandom, depth: Int) -> PropertyValue {
        switch random.nextUInt64() % (depth < 3 ? 9 : 7) {
        case 0: return .null
        case 1: return .bool(random.nextUInt64() % 2 == 0)
        case 2: return .int(Int64(Int32(truncatingIfNeeded: random.nextUInt64())))
        case 3: return .int(Int64(bitPattern: random.nextUInt64()))
        case 4: return .double(Double(Int64(bitPattern: random.nextUInt64()) % 2_000_000) / 1_000 - 1_000)
        case 5, 6: return .string(randomString(random))
        case 7: return .array((0..<Int(random.nextUInt64() % 4)).map { _ in randomValue(random, depth: depth + 1) })
        default: return .object(randomObject(random, depth: depth + 1))
        }
    }

    // Hostile characters included: quotes, backslashes, controls, astral and separator code points.
    static func randomString(_ random: SeededRandom) -> String {
        let pool = Array("aZ09 \"\\/\n\t\u{0}\u{1f}\u{2028}ğş日😀{}[]:,")
        return String(
            (0..<Int(random.nextUInt64() % 12)).map { _ in pool[Int(random.nextUInt64() % UInt64(pool.count))] })
    }
}

@Suite("Json reading fields")
struct JsonReadingTests {
    let device = Json.readObject(
        #"{"v":1,"device_id":"0191","consent":"granted","last_build":140,"retry":{"step":3},"#
            + #""missing_is_fine":null,"future_key":[1,2],"step":"3","ratio":0.5,"huge":1.0E30,"flag":true}"#)

    @Test("reads fields of the right type")
    func rightTypes() throws {
        let device = try #require(device)
        #expect(device.int("v") == 1)
        #expect(device.int64("v") == 1)
        #expect(device.string("device_id") == "0191")
        #expect(device.int64("last_build") == 140)
        #expect(device.fields("retry")?.int("step") == 3)
        #expect(device.object("retry") == ["step": .int(3)])
        #expect(device.double("ratio") == 0.5)
        #expect(device.double("v") == 1.0)
        #expect(device.bool("flag") == true)
    }

    @Test("a missing key is nil, never a default")
    func missing() throws {
        let device = try #require(device)
        #expect(!device.has("user_id"))
        #expect(device.string("user_id") == nil)
        #expect(device.int64("timestamp") == nil)
        #expect(device.int("timestamp") == nil)
        #expect(device.double("timestamp") == nil)
        #expect(device.bool("opted_out") == nil)
        #expect(device.fields("session") == nil)
        #expect(device.object("session") == nil)
    }

    @Test("a wrongly typed value is nil, never coerced")
    func wrongTypes() throws {
        let device = try #require(device)
        #expect(device.int64("step") == nil)
        #expect(device.int("device_id") == nil)
        #expect(device.string("last_build") == nil)
        #expect(device.int64("ratio") == nil)
        #expect(device.int64("huge") == nil)
        #expect(device.bool("consent") == nil)
        #expect(device.double("consent") == nil)
        #expect(device.fields("future_key") == nil)
        #expect(device.int("huge") == nil)
    }

    @Test("an int must fit")
    func intFits() throws {
        let fields = try #require(
            Json.readObject(#"{"big":5000000000,"neg":-9223372036854775808,"over":18446744073709551615}"#))
        #expect(fields.int64("big") == 5_000_000_000)
        #expect(fields.int64("neg") == Int64.min)
        #expect(fields.int64("over") == nil)
        #expect(fields.double("over") == 1.8446744073709552e19)
    }

    @Test("JSON null is present but has no value, and extra keys are kept")
    func nullsAndExtras() throws {
        let device = try #require(device)
        #expect(device.has("missing_is_fine"))
        #expect(device.isNull("missing_is_fine"))
        #expect(!device.isNull("v"))
        #expect(!device.isNull("absent"))
        #expect(device.string("missing_is_fine") == nil)
        #expect(device.keys.isSuperset(of: ["future_key", "v", "retry"]))
        #expect(device.toPropertyValues()["future_key"] == .array([.int(1), .int(2)]))
    }

    @Test(
        "anything but one JSON object is nil",
        arguments: [
            "", "   ", "[1,2]", "\"text\"", "12", "null", "{\"type\":\"track\"", "{\"a\":1}}x", "{a:1", "not json",
            "{\"a\":1} {\"b\":2}",
        ])
    func notAnObject(text: String) {
        #expect(Json.readObject(text) == nil, Comment(rawValue: text))
    }
}
