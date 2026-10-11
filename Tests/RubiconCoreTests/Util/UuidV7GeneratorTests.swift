import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("UuidV7Generator")
struct UuidV7GeneratorTests {
    let clock = TestClock(start: Date(epochMillis: 1_759_147_200_123))
    var generator: UuidV7Generator { UuidV7Generator(clock: clock, random: SeededRandom(seed: 1)) }

    // Lowercase hex of fixed width: string order is numeric order.
    private func assertAscending(_ ids: [String], _ location: SourceLocation = #_sourceLocation) {
        for (a, b) in zip(ids, ids.dropFirst()) {
            #expect(a < b, "\(a) should sort before \(b)", sourceLocation: location)
        }
    }

    private func timestamp(of id: String) -> Int64 {
        let uuid = UUID(uuidString: id)?.uuid ?? (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let bytes = [uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5]
        return bytes.reduce(Int64(0)) { ($0 << 8) | Int64($1) }
    }

    @Test("is a version 7, RFC variant UUID that Foundation parses, in lowercase")
    func layout() throws {
        let id = generator.next()
        let uuid = try #require(UUID(uuidString: id))

        #expect(uuid.uuidString.lowercased() == id)
        #expect(
            id.range(
                of: "^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression
            ) != nil)
        #expect(id == id.lowercased())
    }

    @Test("the timestamp field is the clock's time")
    func timestampField() {
        let generator = generator
        #expect(timestamp(of: generator.next()) == clock.now().epochMillis)
        clock.advance(byMillis: 5_000)
        #expect(timestamp(of: generator.next()) == clock.now().epochMillis)
    }

    @Test("the same seed and clock give the same ids")
    func deterministic() {
        let a = UuidV7Generator(clock: TestClock(start: Date(epochMillis: 0)), random: SeededRandom(seed: 9))
        let b = UuidV7Generator(clock: TestClock(start: Date(epochMillis: 0)), random: SeededRandom(seed: 9))
        #expect((0..<3).map { _ in a.next() } == (0..<3).map { _ in b.next() })
    }

    @Test("10 000 ids in one millisecond are unique and ordered")
    func sameMillisecond() {
        let generator = generator
        let ids = (0..<10_000).map { _ in generator.next() }

        #expect(Set(ids).count == 10_000)
        assertAscending(ids)
        #expect(ids.allSatisfy { timestamp(of: $0) == clock.now().epochMillis })
    }

    @Test("ids of a later millisecond sort after")
    func laterMillisecond() {
        let generator = generator
        let first = (0..<100).map { _ in generator.next() }
        clock.advance(byMillis: 1)
        let second = (0..<100).map { _ in generator.next() }
        assertAscending(first + second)
    }

    @Test("order holds when the clock moves back")
    func clockMovesBack() {
        let generator = generator
        let before = (0..<50).map { _ in generator.next() }
        clock.advance(byMillis: -86_400_000)
        let after = (0..<50).map { _ in generator.next() }

        assertAscending(before + after)
        #expect(timestamp(of: before.last ?? "") == timestamp(of: after.last ?? ""))
    }

    @Test("a full counter moves the timestamp one millisecond ahead")
    func overflow() {
        // A 3-bit counter: seeds 0 to 3, at most 7, so a few ids overflow it.
        let small = UuidV7Generator(clock: clock, random: SeededRandom(seed: 1), counterMax: 7)
        let ids = (0..<40).map { _ in small.next() }

        assertAscending(ids)
        #expect(Set(ids).count == 40)
        #expect(timestamp(of: ids.last ?? "") > clock.now().epochMillis)
    }

    @Test("the counter and tail come from the random source in order")
    func scriptedDraws() {
        // Seed 5 (top bit clear), tail 0xDEADBEEF; the second id increments the counter and draws a new tail.
        let random = ScriptedRandom([5, 0xDEAD_BEEF, 0xCAFE_BABE])
        let generator = UuidV7Generator(clock: TestClock(start: Date(epochMillis: 0x0192_E4A1_7C3F)), random: random)

        let first = generator.next()
        let second = generator.next()

        #expect(first == "0192e4a1-7c3f-7000-8000-0005deadbeef")
        #expect(second == "0192e4a1-7c3f-7000-8000-0006cafebabe")
    }

    @Test("ids from many threads are unique and ordered per thread")
    func manyThreads() {
        let generator = generator
        let threads = 8
        let perThread = 2_000
        let all = Locked<[String]>([])
        let ordered = Locked<[Bool]>([])
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            Thread {
                let mine = (0..<perThread).map { _ in generator.next() }
                ordered.withLock { $0.append(zip(mine, mine.dropFirst()).allSatisfy { $0 < $1 }) }
                all.withLock { $0.append(contentsOf: mine) }
                group.leave()
            }.start()
        }

        #expect(group.wait(timeout: .now() + 30) == .success)
        #expect(Set(all.current).count == threads * perThread)
        #expect(ordered.current == Array(repeating: true, count: threads))
    }
}
