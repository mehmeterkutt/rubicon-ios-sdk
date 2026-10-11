import CoreGraphics
import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

private enum Plan { case free, pro }
private enum Named: CustomStringConvertible {
    case pro
    var description: String { "named-pro" }
}
private enum Payload { case some(Int) }
@objc private enum ObjCPlan: Int { case free, pro }
private struct Custom { let secret: String }
private final class Box { let value = 1 }

@Suite("PropertyNormalizer conversion table")
struct PropertyNormalizerConversionTests {
    private func convert(_ value: Any) -> (PropertyValue?, [PropertyProblem.Kind]) {
        let result = PropertyNormalizer.normalize(["p": value])
        return (result.values["p"], result.problems.map(\.kind))
    }

    private func assertKept(_ expected: PropertyValue, _ value: Any, _ location: SourceLocation = #_sourceLocation) {
        let result = PropertyNormalizer.normalize(["p": value])
        #expect(result.values["p"] == expected, "kept: \(value)", sourceLocation: location)
        #expect(result.problems.isEmpty, sourceLocation: location)
    }

    private func assertDropped(
        _ kind: PropertyProblem.Kind, _ value: Any, type: String? = nil, _ location: SourceLocation = #_sourceLocation
    ) {
        let result = PropertyNormalizer.normalize(["p": value, "other": "kept"])
        #expect(result.values == ["other": .string("kept")], "dropped: \(value)", sourceLocation: location)
        #expect(result.problems.map(\.kind) == [kind], sourceLocation: location)
        #expect(result.problems.first?.path == "p", sourceLocation: location)
        if let type { #expect(result.problems.first?.type == type, sourceLocation: location) }
    }

    @Test("String, Bool, Int, Int64, Double, nil and NSNull are kept as they are")
    func plainTypes() {
        assertKept(.string("a"), "a")
        assertKept(.bool(true), true)
        assertKept(.int(7), 7)
        assertKept(.int(7), Int64(7))
        assertKept(.double(1.5), 1.5)
        assertKept(.null, NSNull())
        let optional: Int? = nil
        assertKept(.null, optional as Any)
        let wrapped: Int? = 3
        assertKept(.int(3), wrapped as Any)
    }

    @Test("the four boxed-boolean cases of iOS Public API 5")
    func boxedBooleans() {
        assertKept(.bool(true), true)
        assertKept(.bool(true), NSNumber(value: true))
        assertKept(.int(1), NSNumber(value: 1))
        assertKept(.int(1), NSNumber(value: Int8(1)))
        assertKept(.bool(false), NSNumber(value: false))
        assertKept(.int(0), NSNumber(value: 0))
    }

    @Test("every integer width becomes Int64; UInt64 above Int64.max is out of range")
    func integers() {
        assertKept(.int(7), Int8(7))
        assertKept(.int(-7), Int16(-7))
        assertKept(.int(7), Int32(7))
        assertKept(.int(7), UInt8(7))
        assertKept(.int(7), UInt16(7))
        assertKept(.int(7), UInt32(7))
        assertKept(.int(7), UInt(7))
        assertKept(.int(Int64.max), UInt64(Int64.max))
        assertKept(.int(Int64.min), Int64.min)
        assertDropped(.outOfRange, UInt64.max, type: "UInt64")
    }

    @Test("Float and Decimal go through their decimal text; CGFloat is a Double")
    func floatsAndDecimals() {
        assertKept(.double(0.1), Float(0.1))
        assertKept(.double(1.5), Float(1.5))
        assertKept(.double(2.5), CGFloat(2.5))
        assertKept(.double(19.99), Decimal(string: "19.99") ?? Decimal())
        assertKept(.double(19.99), NSDecimalNumber(string: "19.99"))
        assertDropped(.outOfRange, Decimal.nan, type: "Decimal")
        assertDropped(.notFinite, Float.nan)
        assertDropped(.notFinite, Float.infinity)
    }

    @Test("NaN and infinity are unsupported as Double")
    func notFinite() {
        for value in [Double.nan, .infinity, -.infinity] {
            assertDropped(.notFinite, value, type: "Double")
        }
    }

    @Test("Character becomes a one-character string, Date the ISO string, URL its absolute string")
    func charactersDatesUrls() throws {
        assertKept(.string("A"), Character("A"))
        assertKept(.string("1970-01-01T00:00:00.000Z"), Date(epochMillis: 0))
        assertKept(.string("2026-10-13T08:00:00.000Z"), Date(epochMillis: 1_791_878_400_000))
        assertDropped(.outOfRange, Date(epochMillis: 253_402_300_800_000), type: "Date")
        assertKept(.string("https://a.com/b?c=1"), try #require(URL(string: "https://a.com/b?c=1")))
    }

    @Test("a payload-free enum is its case name; the documented caveats hold")
    func enums() {
        assertKept(.string("pro"), Plan.pro)
        assertKept(.string("named-pro"), Named.pro)
        assertKept(.int(1), ObjCPlan.pro)
        assertDropped(.unsupportedType, Payload.some(1), type: "Payload")
    }

    @Test("arrays, sets and other collections become lists; a dictionary with string keys is copied")
    func collections() {
        assertKept(.array([.int(1), .string("a"), .null]), [1, "a", NSNull()] as [Any])
        assertKept(.array([.int(1), .int(2)]), [1, 2])
        assertKept(.array([.double(0.1)]), [Float(0.1)])
        assertKept(.array([.int(1), .int(2)]), NSArray(array: [1, 2]))
        assertKept(.array([.string("a")]), Set(["a"]))
        assertKept(.array([.int(3), .int(1)]), [3, 1][...])
        assertKept(.object(["k": .int(1), "n": .null]), ["k": 1, "n": NSNull()] as [String: Any])
        assertKept(.object(["k": .int(1)]), NSDictionary(dictionary: ["k": 1]))
    }

    @Test("a dictionary whose keys are not strings keeps only the string-keyed entries")
    func nonStringKeys() {
        let result = PropertyNormalizer.normalize(["m": [1: "a", "b": 2] as [AnyHashable: Any]])
        #expect(result.values == ["m": .object(["b": .int(2)])])
        #expect(result.problems == [PropertyProblem(.invalidKey, path: "m", type: "Int")])

        let intKeyed = PropertyNormalizer.normalize(["m": [1: "a", 2: "b"]])
        #expect(intKeyed.values == ["m": .object([:])])
        #expect(intKeyed.problems.map(\.kind) == [.invalidKey, .invalidKey])
    }

    @Test("an NSString with a lone surrogate is bridged with U+FFFD")
    func loneSurrogate() {
        var units: [unichar] = [0x61, 0xD800, 0x62]
        let text = NSString(characters: &units, length: 3)
        assertKept(.string("a\u{FFFD}b"), text)
    }

    @Test("anything else is unsupported, with the type named and never the value")
    func unsupported() {
        assertDropped(.unsupportedType, Custom(secret: "s3cr3t"), type: "Custom")
        assertDropped(.unsupportedType, Box(), type: "Box")
        assertDropped(.unsupportedType, Data([1, 2]), type: "Data")
        assertDropped(.unsupportedType, (1, 2), type: "(Int, Int)")
        let closure: @Sendable () -> Void = {}
        assertDropped(.unsupportedType, closure)
        let result = PropertyNormalizer.normalize(["custom": Custom(secret: "s3cr3t-value")])
        #expect(!result.problems.contains { $0.message.contains("s3cr3t") })
    }
}

@Suite("PropertyNormalizer structure and limits")
struct PropertyNormalizerLimitTests {
    @Test("a bad element drops only that element and paths name nested keys and positions")
    func nestedElements() {
        let result = PropertyNormalizer.normalize(["list": [1, Custom(secret: "x"), 3, Double.nan] as [Any]])
        #expect(result.values == ["list": .array([.int(1), .int(3)])])
        #expect(result.problems.map(\.path) == ["list[1]", "list[3]"])

        let nested = PropertyNormalizer.normalize(["cart": ["items": [["sku": "A1"], ["sku": Custom(secret: "x")]]]])
        #expect(nested.problems.map(\.path) == ["cart.items[1].sku"])
        #expect(nested.values == ["cart": .object(["items": .array([.object(["sku": .string("A1")]), .object([:])])])])
    }

    @Test("a blank key, a key of 256 characters and a padded key")
    func keys() {
        let result = PropertyNormalizer.normalize(["": 1, "  ": 2, "ok": 3, " padded ": 4])
        #expect(Set(result.values.keys) == ["ok", " padded "])
        #expect(result.problems.map(\.kind) == [.invalidKey, .invalidKey])

        let key254 = String(repeating: "k", count: 254)
        let key255 = String(repeating: "k", count: 255)
        let key256 = String(repeating: "k", count: 256)
        let lengths = PropertyNormalizer.normalize([key254: 1, key255: 2, key256: 3])
        #expect(Set(lengths.values.keys) == [key254, key255])
        #expect(lengths.problems.first?.type == "256 characters")
    }

    @Test("1023 and 1024 characters are kept, 1025 are cut to 1024 without a marker, never inside a pair")
    func strings() {
        let a1023 = String(repeating: "a", count: 1023)
        let a1024 = String(repeating: "a", count: 1024)
        #expect(PropertyNormalizer.normalize(["p": a1023]).values["p"] == .string(a1023))
        #expect(PropertyNormalizer.normalize(["p": a1024]).problems.isEmpty)

        let cut = PropertyNormalizer.normalize(["p": a1024 + "b"])
        #expect(cut.values["p"] == .string(a1024))
        #expect(cut.problems.map(\.kind) == [.truncated])

        let pair = PropertyNormalizer.normalize(["p": a1023 + "😀" + "b"])
        #expect(pair.values["p"] == .string(a1023))
    }

    @Test("three levels of nesting are allowed, the fourth is dropped")
    func depth() {
        let three: [String: Any] = ["cart": ["items": [["sku": "A1", "qty": 2]]]]
        #expect(PropertyNormalizer.normalize(three).problems.isEmpty)

        let four: [String: Any] = ["a": ["b": ["c": ["d": ["e": 1]]], "keep": 1]]
        let result = PropertyNormalizer.normalize(four)
        #expect(result.values == ["a": .object(["b": .object(["c": .object([:])]), "keep": .int(1)])])
        #expect(result.problems.map(\.kind) == [.tooDeep])
        #expect(result.problems.first?.path == "a.b.c.d")
        #expect(result.problems.first?.type?.hasPrefix("Dictionary") == true)

        let deepList: [String: Any] = ["l": [[[[1]]]]]
        #expect(PropertyNormalizer.normalize(deepList).problems.map(\.kind) == [.tooDeep])
    }

    @Test("a dictionary that contains itself stops at the depth limit")
    func selfReference() {
        let loop = NSMutableDictionary()
        loop["self"] = loop
        loop["n"] = 1
        let result = PropertyNormalizer.normalize(["loop": loop])
        #expect(result.problems.map(\.kind) == [.tooDeep])
        let array = NSMutableArray()
        array.add(array)
        #expect(PropertyNormalizer.normalize(["loop": array]).problems.map(\.kind) == [.tooDeep])
    }

    private func properties(_ count: Int, prefix: String = "p") -> [String: Any] {
        Dictionary(uniqueKeysWithValues: (1...count).map { ("\(prefix)\($0)", $0) })
    }

    private func values(_ count: Int, prefix: String = "p") -> [String: PropertyValue] {
        Dictionary(uniqueKeysWithValues: (1...count).map { ("\(prefix)\($0)", PropertyValue.int(Int64($0))) })
    }

    @Test("255 and 256 properties are kept, the 257th is dropped")
    func count() {
        #expect(PropertyNormalizer.normalize(properties(255)).values.count == 255)
        #expect(PropertyNormalizer.normalize(properties(256)).problems.isEmpty)
        let result = PropertyNormalizer.normalize(properties(257))
        #expect(result.values.count == 256)
        #expect(result.problems == [PropertyProblem(.tooMany, path: "", count: 1)])
    }

    @Test("super properties merge in, the event's own key wins, and above 256 they are dropped first")
    func superProperties() {
        let merged = PropertyNormalizer.mergeSuperProperties(
            own: ["plan": .string("event"), "a": .int(1)], superProperties: ["plan": .string("super"), "b": .int(2)])
        #expect(merged.values == ["plan": .string("event"), "a": .int(1), "b": .int(2)])
        #expect(merged.problems.isEmpty)

        let crowded = PropertyNormalizer.mergeSuperProperties(
            own: values(250), superProperties: values(10, prefix: "s"))
        #expect(crowded.values.count == 256)
        #expect(Set(values(250).keys).isSubset(of: crowded.values.keys))
        #expect(crowded.problems == [PropertyProblem(.tooMany, path: "", count: 4)])

        let full = PropertyNormalizer.mergeSuperProperties(
            own: values(256), superProperties: ["p1": .string("super"), "s": .int(1)])
        #expect(full.values == values(256))
        #expect(full.problems.first?.count == 1)
    }

    @Test("a name of 1 to 255 characters is valid and never trimmed; blank or 256 is invalid")
    func names() {
        #expect(PropertyNormalizer.checkName("a") == nil)
        #expect(PropertyNormalizer.checkName(" Purchase Completed ") == nil)
        #expect(PropertyNormalizer.checkName(String(repeating: "n", count: 255)) == nil)
        for name in ["", "   ", String(repeating: "n", count: 256)] {
            #expect(PropertyNormalizer.checkName(name)?.kind == .invalidName)
        }
    }

    @Test("changing the caller's reference collections afterwards changes nothing")
    func deepCopy() {
        let tags = NSMutableArray(array: ["a"])
        let nested = NSMutableDictionary(dictionary: ["tags": tags])
        let input: [String: Any] = ["nested": nested, "n": 1]

        let result = PropertyNormalizer.normalize(input)
        nested["extra"] = true
        tags.add("b")

        #expect(result.values == ["nested": .object(["tags": .array([.string("a")])]), "n": .int(1)])
    }
}

@Suite("PropertyProblem reporting")
struct PropertyProblemReportingTests {
    let test = TestPlatform()
    let counted = Locked<[Code]>([])

    private func log(level: LogLevel = .debug) -> Log {
        Log(
            level: level, logger: nil, platformLogger: test.logger.asLogger,
            issues: { [counted] code in counted.withLock { $0.append(code) } },
            developerError: { [test] message in test.developerErrors.withLock { $0.append(message) } })
    }

    @Test("in release every problem is logged with its code and no developer error is raised")
    func release() {
        let result = PropertyNormalizer.normalize([
            "t": Custom(secret: "x"), "long": String(repeating: "x", count: 2_000), "": 1,
        ])
        PropertyProblem.report(result.problems, debug: false, log: log())

        #expect(
            counted.current.sorted { $0.rawValue < $1.rawValue } == [
                .propertyDropped, .propertyDropped, .propertyTruncated,
            ])
        #expect(test.logger.lines.first?.level == .warn)
        #expect(test.logger.messages.first?.hasPrefix("PROPERTY_") == true)
        #expect(test.developerErrors.current.isEmpty)
    }

    @Test("in debug each developer error is reported with its message, and still logged")
    func debug() {
        let result = PropertyNormalizer.normalize(["bad": Custom(secret: "x")])
        PropertyProblem.report(result.problems, debug: true, log: log())

        #expect(test.developerErrors.current == ["Property \"bad\" dropped: Custom is not supported."])
        #expect(test.logger.messages == ["PROPERTY_DROPPED: Property \"bad\" dropped: Custom is not supported."])
    }

    @Test("a truncation is never a developer error, even in debug, and is logged once per key")
    func truncation() {
        let log = log()
        for _ in 0..<2 {
            let result = PropertyNormalizer.normalize([
                "bio": String(repeating: "x", count: 2_000), "note": String(repeating: "y", count: 2_000),
            ])
            PropertyProblem.report(result.problems, debug: true, log: log)
        }
        #expect(test.developerErrors.current.isEmpty)
        #expect(test.logger.lines.filter { $0.level == .warn }.count == 2)
        #expect(counted.current.count == 4)
    }

    @Test("each kind has a message and the documented code")
    func kinds() {
        for kind in PropertyProblem.Kind.allCases {
            let problem = PropertyProblem(kind, path: "p", type: "Type", count: 3)
            #expect(!problem.message.isEmpty)
            #expect(problem.description.contains("\(kind)"))
        }
        #expect(PropertyProblem.Kind.invalidName.code == .invalidEventName)
        #expect(PropertyProblem.Kind.tooMany.code == .tooManyProperties)
        #expect(!PropertyProblem.Kind.truncated.isDeveloperError)
        #expect(PropertyProblem.Kind.allCases.filter { !$0.isDeveloperError }.count == 1)
    }
}

@Suite("PropertyNormalizer robustness")
struct PropertyNormalizerFuzzTests {
    @Test("seeded random dictionaries never trap and always give valid JSON")
    func fuzz() throws {
        let random = SeededRandom(seed: 2025)
        let log = Log(level: .off, logger: nil, platformLogger: noOpLogger)
        for _ in 0..<3_000 {
            let result = PropertyNormalizer.normalize(Self.randomDictionary(random, depth: 0))
            let line = try Json.write(result.values)
            _ = try JSONValue.parse(line)
            PropertyProblem.report(result.problems, debug: false, log: log)
        }
    }

    static func randomDictionary(_ random: SeededRandom, depth: Int) -> [String: Any] {
        var dictionary: [String: Any] = [:]
        for _ in 0..<Int(random.nextUInt64() % 8) {
            dictionary[randomKey(random)] = randomValue(random, depth: depth)
        }
        return dictionary
    }

    static func randomKey(_ random: SeededRandom) -> String {
        switch random.nextUInt64() % 12 {
        case 0: return ""
        case 1: return "   "
        case 2: return String(repeating: "k", count: 256)
        default: return randomString(random, 12)
        }
    }

    static func randomValue(_ random: SeededRandom, depth: Int) -> Any {
        switch random.nextUInt64() % 24 {
        case 0: return NSNull()
        case 1: return random.nextUInt64() % 2 == 0
        case 2: return Int32(truncatingIfNeeded: random.nextUInt64())
        case 3: return Int64(bitPattern: random.nextUInt64())
        case 4: return Double(random.nextUInt64() % 1_000_000) / 7
        case 5: return [Double.nan, -Double.infinity, Float.infinity][Int(random.nextUInt64() % 3)]
        case 6: return Float(random.nextUInt64() % 1_000) / 3
        case 7: return Decimal(Double(random.nextUInt64() % 1_000_000) / 100)
        case 8: return UInt64(random.nextUInt64())
        case 9:
            return Date(epochMillis: Int64(bitPattern: random.nextUInt64() % 400_000_000_000_000) - 100_000_000_000_000)
        case 10: return Custom(secret: "x")
        case 11: return random.nextUInt64() % 2 == 0 ? Plan.pro : Plan.free
        case 12: return Box()
        case 13: return Character(UnicodeScalar(UInt8(truncatingIfNeeded: random.nextUInt64())))
        case 14: return randomString(random, 2_000)
        case 15: return [Int32(truncatingIfNeeded: random.nextUInt64()), 1]
        case 16: return Set([Int(random.nextUInt64() % 10), 42])
        case 17, 18: return (0..<Int(random.nextUInt64() % 4)).map { _ in randomValue(random, depth: depth + 1) }
        case 19: return NSNumber(value: random.nextUInt64() % 2 == 0)
        default: return depth < 6 ? randomDictionary(random, depth: depth + 1) : "leaf"
        }
    }

    // Random scalars: controls, quotes, separators and astral characters included.
    static func randomString(_ random: SeededRandom, _ maxLength: Int) -> String {
        let count = Int(random.nextUInt64() % UInt64(maxLength + 1))
        var scalars = String.UnicodeScalarView()
        for _ in 0..<count {
            if let scalar = UnicodeScalar(UInt32(random.nextUInt64() % 0x11000)) { scalars.append(scalar) }
        }
        return String(scalars)
    }
}
