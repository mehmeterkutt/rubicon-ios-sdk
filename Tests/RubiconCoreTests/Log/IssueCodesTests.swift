import Foundation
import Testing

@testable import RubiconCore

// Keeps docs/issue-codes.md and Code in step: every iOS code is documented, once, with its level.
@Suite("Issue code catalogue")
struct IssueCodesTests {
    struct Row {
        let code: String
        let level: String
        let platform: String
    }

    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let rows: [Row] = {
        let text = (try? String(contentsOf: root.appendingPathComponent("docs/issue-codes.md"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").filter { $0.hasPrefix("| `") }.map { line in
            let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            return Row(
                code: cells[0].trimmingCharacters(in: CharacterSet(charactersIn: "`")), level: cells[1],
                platform: cells[2])
        }
    }()

    @Test("every iOS code is documented once, and every documented iOS code exists")
    func catalogueMatchesEnum() {
        let documentedForIOS = Self.rows.filter { $0.platform != "Android" }.map(\.code)
        #expect(documentedForIOS.sorted() == Code.allCases.map(\.rawValue).sorted())
        #expect(Set(Self.rows.map(\.code)).count == Self.rows.count)
        #expect(!Self.rows.isEmpty)
    }

    @Test("every documented level is WARN or ERROR and every platform is both, Android or iOS")
    func levelsAndPlatforms() {
        for row in Self.rows {
            #expect(row.level == "WARN" || row.level == "ERROR", "\(row.code) has level \(row.level)")
            #expect(["both", "Android", "iOS"].contains(row.platform), "\(row.code) has platform \(row.platform)")
        }
    }

    @Test("the documentation comment of each code states the documented level")
    func docCommentsStateLevel() throws {
        let source = try String(
            contentsOf: Self.root.appendingPathComponent("Sources/RubiconCore/log/Code.swift"), encoding: .utf8)
        for row in Self.rows where row.platform != "Android" {
            let pattern = #"/// (WARN|ERROR)\. [^\n]*\n\s*case \w+ = ""# + row.code + #"""#
            let regex = try NSRegularExpression(pattern: pattern)
            let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))
            let level = match.flatMap { Range($0.range(at: 1), in: source) }.map { String(source[$0]) }
            #expect(level == row.level, "\(row.code)")
        }
    }
}
