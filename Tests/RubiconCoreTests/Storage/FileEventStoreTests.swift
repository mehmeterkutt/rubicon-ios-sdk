import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The Android `FileEventStoreTest`, ported, plus the locked state of iOS Disk 1.
final class EventStoreHarness: @unchecked Sendable {
    static let key = "api-key"
    static let now: Int64 = 1_759_147_200_000
    static let sentAt = Date(epochMillis: 1_759_147_260_000)

    let test = TestPlatform()
    let clock = TestClock(start: Date(epochMillis: EventStoreHarness.now))
    let dropped = Locked<[DropReason: Int]>([:])
    lazy var log = test.log()
    var fs: FakeFileSystem { test.fileSystem }
    var root: URL { test.storageRoot }
    var dir: URL {
        root.appendingPathComponent("events/v1/\(Hashing.sha256Hex(Self.key).prefix(16))", isDirectory: true)
    }

    var drops: DropCounter {
        { [dropped] reason, n in dropped.withLock { $0[reason, default: 0] += n } }
    }

    func store(key: String = EventStoreHarness.key) -> FileEventStore {
        let store = FileEventStore(root: root, fileSystem: fs)
        _ = store.open(apiKey: key, clock: clock, log: log, drops: drops)
        return store
    }

    func line(_ id: String, timestamp: Int64 = EventStoreHarness.now, padding: Int = 0) -> String {
        #"{"type":"track","event":"E","message_id":"\#(id)","timestamp":\#(timestamp),"properties":{"p":"\#(String(repeating: "x", count: padding))"}}"#
    }

    func body(_ store: FileEventStore, _ index: Int64) throws -> (ids: [String], body: String) {
        guard case .written(let ids, let body) = store.writeBatch(index: index, sentAt: Self.sentAt) else {
            throw NSError(domain: "harness", code: 1, userInfo: [NSLocalizedDescriptionKey: "not written"])
        }
        return (ids, String(decoding: body, as: UTF8.self))
    }

    func ids(_ store: FileEventStore, _ index: Int64) throws -> [String] { try body(store, index).ids }

    func files() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    func read(_ name: String) throws -> String {
        String(decoding: try Data(contentsOf: dir.appendingPathComponent(name)), as: UTF8.self)
    }

    func logged(_ code: Code) -> Bool { test.logger.messages.contains { $0.hasPrefix("\(code.rawValue):") } }
    func count(_ reason: DropReason) -> Int? { dropped.current[reason] }
}

@Suite("FileEventStore segments")
struct FileEventStoreSegmentTests {
    let h = EventStoreHarness()

    @Test("a segment closes at 100 events and is renamed")
    func closesAt100() throws {
        let store = h.store()
        for i in 0..<250 { _ = store.append(h.line("e\(i)")) }
        #expect(store.closedSegments() == [0, 1])
        #expect(try h.files() == ["0000000000", "0000000001", "0000000002.tmp"])
        #expect(store.pendingCount == 250)
        #expect(try h.ids(store, 0) == (0..<100).map { "e\($0)" })
    }

    @Test("a segment closes before a line that would pass 512 KB")
    func closesAtBytes() throws {
        let store = h.store()
        for i in 0..<40 { _ = store.append(h.line("e\(i)", padding: 30_000)) }
        store.closeOpenSegment()
        for index in store.closedSegments() {
            let size =
                try FileManager.default.attributesOfItem(
                    atPath: h.dir.appendingPathComponent(String(format: "%010lld", index)).path)[.size] as? Int
            #expect((size ?? 0) <= Int(FileEventStore.maxBytes))
        }
        #expect(store.closedSegments().count >= 3)
        #expect(try store.closedSegments().flatMap { try h.ids(store, $0) } == (0..<40).map { "e\($0)" })
    }

    @Test("closing on request makes a batch, and an empty open segment is not closed")
    func closeOnRequest() throws {
        let store = h.store()
        store.closeOpenSegment()
        _ = store.append(h.line("a"))
        store.closeOpenSegment()
        store.closeOpenSegment()
        #expect(store.closedSegments() == [0])
        #expect(try h.files() == ["0000000000"])
    }

    @Test("each line is one write of the line and its line break")
    func lineWrites() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        _ = store.append(h.line("b"))
        #expect(try h.read("0000000000.tmp") == h.line("a") + "\n" + h.line("b") + "\n")
    }

    @Test("index order survives a restart and gaps")
    func indexes() throws {
        let first = h.store()
        for i in 0..<3 {
            _ = first.append(h.line("e\(i)"))
            first.closeOpenSegment()
        }
        first.deleteSegment(1)

        let restarted = h.store()
        _ = restarted.append(h.line("next"))
        restarted.closeOpenSegment()

        #expect(restarted.closedSegments() == [0, 2, 3])
        #expect(try h.ids(restarted, 3) == ["next"])
        #expect(restarted.pendingCount == 3)
    }

    @Test("10 000 events are read back in order")
    func tenThousand() throws {
        var read: [String] = []
        func drain(_ store: FileEventStore) throws {
            for index in store.closedSegments() {
                read += try h.ids(store, index)
                store.deleteSegment(index)
            }
        }
        let store = h.store()
        for i in 0..<10_000 {
            _ = store.append(h.line("e\(i)"))
            if i % 900 == 899 { try drain(store) }
        }
        let last = h.store()
        last.closeOpenSegment()
        try drain(last)
        #expect(read == (0..<10_000).map { "e\($0)" })
        #expect(h.count(.queueFull) == nil)
    }

    @Test("files are app-private")
    func permissions() throws {
        _ = h.store().append(h.line("a"))
        let attributes = try FileManager.default.attributesOfItem(
            atPath: h.dir.appendingPathComponent("0000000000.tmp").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}

@Suite("FileEventStore batch body and corrupt lines")
struct FileEventStoreBodyTests {
    let h = EventStoreHarness()

    @Test("the body is the stored lines joined, byte for byte, and matches envelope.json structurally")
    func body() throws {
        let store = h.store()
        let lines = [
            h.line("a"), h.line("ö-💳"),
            #"{"type":"screen","name":"s","message_id":"c","timestamp":\#(EventStoreHarness.now),"x":"\/"}"#,
        ]
        for line in lines { _ = store.append(line) }
        store.closeOpenSegment()

        let (ids, body) = try h.body(store, 0)
        #expect(
            body == #"{"sent_at":\#(EventStoreHarness.sentAt.epochMillis),"batch":[\#(lines.joined(separator: ","))]}"#)
        #expect(ids == ["a", "ö-💳", "c"])
        guard case .object(let parsed) = try JSONValue.parse(body), case .array(let batch)? = parsed["batch"] else {
            Issue.record("not an object")
            return
        }
        #expect(parsed["sent_at"] == .number(Double(EventStoreHarness.sentAt.epochMillis)))
        #expect(batch.count == 3)
    }

    @Test("the envelope golden file: the stored lines stream unchanged after sent_at")
    func envelope() throws {
        let golden = try SampleEvents.golden("envelope")
        guard case .object(let expected) = golden, case .array(let batch)? = expected["batch"],
            case .number(let sentAt)? = expected["sent_at"]
        else {
            Issue.record("envelope.json shape")
            return
        }
        let url = try #require(
            Bundle.module.url(forResource: "envelope", withExtension: "json", subdirectory: "Fixtures/golden"))
        let text = try String(contentsOf: url, encoding: .utf8)
        // The lines of the file, each one event, compact as stored.
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("{\"type\"") }.map { $0.hasSuffix(",") ? String($0.dropLast()) : $0 }
        #expect(lines.count == batch.count)
        let store = h.store()
        for line in lines { _ = store.append(line) }
        store.closeOpenSegment()

        let (_, body) = try h.body(store, 0)
        var parsedBody = try JSONValue.parse(body)
        if case .object(let object) = parsedBody, case .array(let events)? = object["batch"] {
            parsedBody = .object(
                with(object) { $0["batch"] = .array(events.map(SampleEvents.removingAndroidOnlyFields)) })
        }
        let goldenWithoutAndroidFields: JSONValue = .object(
            with(expected) { $0["batch"] = .array(batch.map(SampleEvents.removingAndroidOnlyFields)) })
        #expect(parsedBody == goldenWithoutAndroidFields)
        #expect(sentAt == Double(1_759_147_260_000))
    }

    @Test("an empty segment gives an empty batch")
    func emptySegment() {
        #expect(
            h.store().writeBatch(index: 42, sentAt: EventStoreHarness.sentAt) == .written(messageIds: [], body: Data()))
    }

    @Test("corrupt lines are skipped, logged without content and counted once when the segment is deleted")
    func corruptLines() throws {
        try h.write(
            "0000000000",
            [
                h.line("a"), "not json", "[1,2]", #"{"message_id":"no-type","timestamp":1}"#,
                #"{"type":"track","timestamp":1}"#,
                #"{"type":"track","message_id":"secret-id","timestamp":"1"}"#,
                #"{"type":"track","message_id":"x","timestamp":1.5}"#,
                h.line("b"),
            ].map { $0 + "\n" }.joined())
        let store = h.store()

        let (ids, body) = try h.body(store, 0)
        _ = try h.body(store, 0)
        store.deleteSegment(0)

        #expect(ids == ["a", "b"])
        #expect(
            body == #"{"sent_at":\#(EventStoreHarness.sentAt.epochMillis),"batch":[\#(h.line("a")),\#(h.line("b"))]}"#)
        #expect(h.count(.corrupt) == 6)
        let corrupt = h.test.logger.lines.filter { $0.message.hasPrefix("CORRUPT_LINE") }
        #expect(corrupt.first?.level == .error)
        #expect(corrupt.first?.message == "CORRUPT_LINE: Skipped corrupt line 2 of segment 0000000000")
        #expect(corrupt.contains { $0.message.hasSuffix("line 6 of segment 0000000000, message_id secret-id") })
        #expect(corrupt.dropFirst().allSatisfy { $0.level == .debug })
        #expect(corrupt.count == 6)
        #expect(!h.test.logger.messages.contains { $0.contains("not json") })
    }

    @Test("a segment of corrupt lines only gives an empty batch")
    func allCorrupt() throws {
        try h.write("0000000000", "x\ny\n")
        #expect(try h.ids(h.store(), 0).isEmpty)
    }
}

@Suite("FileEventStore leftover open segment")
struct FileEventStoreLeftoverTests {
    let h = EventStoreHarness()

    @Test("complete lines are kept and the segment is closed")
    func recovered() throws {
        let first = h.store()
        _ = first.append(h.line("a"))
        _ = first.append(h.line("b"))
        let restarted = h.store()
        #expect(restarted.closedSegments() == [0])
        #expect(try h.ids(restarted, 0) == ["a", "b"])
        #expect(restarted.pendingCount == 2)
        #expect(try h.files() == ["0000000000"])
    }

    @Test("a half-written last line is dropped as corrupt; a leftover with no complete line is deleted")
    func halfLine() throws {
        try h.write("0000000004.tmp", h.line("a") + "\n" + String(h.line("b").prefix(20)))
        let store = h.store()
        #expect(try h.ids(store, 4) == ["a"])
        #expect(h.count(.corrupt) == 1)
        #expect(h.logged(.corruptLine))
        #expect(try h.read("0000000004") == h.line("a") + "\n")

        let other = EventStoreHarness()
        try other.write("0000000000.tmp", "{\"type\":")
        let empty = other.store()
        #expect(empty.closedSegments().isEmpty)
        #expect(try other.files().isEmpty)
        #expect(other.count(.corrupt) == 1)
    }

    @Test("a truncation at every byte of the last line recovers the lines before it")
    func everyCut() throws {
        let first = h.line("first")
        let last = h.line("last-ö")
        let lastBytes = Data((last + "\n").utf8)
        let random = SeededRandom(seed: 42)
        for cut in 0...lastBytes.count {
            let caseRoot = h.root.appendingPathComponent("cut-\(cut)", isDirectory: true)
            let caseDir = caseRoot.appendingPathComponent(
                "events/v1/\(Hashing.sha256Hex(EventStoreHarness.key).prefix(16))", isDirectory: true)
            try FileManager.default.createDirectory(at: caseDir, withIntermediateDirectories: true)
            let index = Int64(random.nextUInt64() % 9_999_999_999)
            var content = Data((first + "\n").utf8)
            content.append(lastBytes.prefix(cut))
            try content.write(to: caseDir.appendingPathComponent(String(format: "%010lld.tmp", index)))
            let counted = Locked<[DropReason: Int]>([:])

            let store = FileEventStore(root: caseRoot, fileSystem: PosixFileSystem())
            _ = store.open(apiKey: EventStoreHarness.key, clock: h.clock, log: h.log) { reason, n in
                counted.withLock { $0[reason] = n }
            }
            var ids: [String] = []
            for idx in store.closedSegments() {
                if case .written(let found, _) = store.writeBatch(index: idx, sentAt: EventStoreHarness.sentAt) {
                    ids += found
                }
            }
            let complete = cut == lastBytes.count
            #expect(ids == (complete ? ["first", "last-ö"] : ["first"]), "cut at \(cut)")
            #expect(counted.current[.corrupt] == ((complete || cut == 0) ? nil : 1), "cut at \(cut)")
        }
    }
}

@Suite("FileEventStore startup, age and capacity")
struct FileEventStoreLifecycleTests {
    let h = EventStoreHarness()
    let threeDays = FileEventStore.maxAgeMillis

    @Test("events of another API key are deleted and counted; a later format directory is never touched")
    func otherKeys() throws {
        let old = h.store(key: "old-key")
        for i in 0..<150 { _ = old.append(h.line("e\(i)")) }
        let v2 = h.root.appendingPathComponent("events/v2/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: v2, withIntermediateDirectories: true)
        try Data("future\n".utf8).write(to: v2.appendingPathComponent("0000000000"))

        let store = h.store()

        #expect(h.count(.apiKeyChanged) == 150)
        #expect(h.logged(.apiKeyChanged))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: h.root.appendingPathComponent("events/v1").path) == [
                h.dir.lastPathComponent
            ])
        #expect(store.pendingCount == 0)
        #expect(
            String(decoding: try Data(contentsOf: v2.appendingPathComponent("0000000000")), as: UTF8.self) == "future\n"
        )
    }

    @Test("unknown files are deleted with a warning; the pending count comes from the lines on disk")
    func unknownFiles() throws {
        try h.write("notes.txt", "x")
        try h.write("123", "x")
        try FileManager.default.createDirectory(
            at: h.dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try h.write("0000000001", h.line("a") + "\n")

        let store = h.store()

        #expect(try h.files() == ["0000000001"])
        #expect(h.logged(.unknownFile))
        #expect(store.pendingCount == 1)
        #expect(h.count(.corrupt) == nil)

        let other = EventStoreHarness()
        let first = other.store()
        for i in 0..<130 { _ = first.append(other.line("e\(i)")) }
        #expect(other.store().pendingCount == 130)
    }

    @Test("an event exactly 3 days old is kept, one millisecond older is not; a future timestamp never expires")
    func exactAge() throws {
        let store = h.store()
        _ = store.append(h.line("kept", timestamp: EventStoreHarness.now - threeDays))
        _ = store.append(h.line("gone", timestamp: EventStoreHarness.now - threeDays - 1))
        _ = store.append(h.line("future", timestamp: EventStoreHarness.now + threeDays * 10))
        store.closeOpenSegment()
        store.expire()
        #expect(try h.ids(store, 0) == ["kept", "future"])
    }

    @Test(
        "a segment of expired events is deleted at startup and counted; expire before an upload deletes aged segments")
    func expiredSegments() throws {
        let first = h.store()
        for i in 0..<5 { _ = first.append(h.line("old\(i)", timestamp: EventStoreHarness.now - threeDays - 1)) }
        first.closeOpenSegment()
        _ = first.append(h.line("new"))
        first.closeOpenSegment()

        let restarted = h.store()
        #expect(restarted.closedSegments() == [1])
        #expect(h.count(.expired) == 5)
        #expect(h.logged(.eventsExpired))
        #expect(restarted.pendingCount == 1)

        h.clock.advance(byMillis: threeDays + 1)
        restarted.expire()
        #expect(restarted.closedSegments().isEmpty)
        #expect(h.count(.expired) == 6)
    }

    @Test("expired lines of a partly expired segment are skipped and counted on deletion")
    func partlyExpired() throws {
        let store = h.store()
        _ = store.append(h.line("old", timestamp: EventStoreHarness.now - threeDays - 1))
        _ = store.append(h.line("new"))
        store.closeOpenSegment()
        store.expire()
        #expect(try h.ids(store, 0) == ["new"])
        #expect(h.count(.expired) == nil)
        store.deleteSegment(0)
        #expect(h.count(.expired) == 1)
    }

    @Test("passing 1000 events drops the oldest segments down to 900 and counts them")
    func capacity() throws {
        let store = h.store()
        for i in 0..<1000 { _ = store.append(h.line("e\(i)")) }
        #expect(store.pendingCount == 1000)
        #expect(h.count(.queueFull) == nil)

        _ = store.append(h.line("e1000"))

        #expect(store.pendingCount == 901 - 100)
        #expect(h.count(.queueFull) == 200)
        #expect(h.logged(.queueFull))
        #expect(try h.ids(store, store.closedSegments()[0]).first == "e200")
    }

    @Test("small segments are trimmed one by one until at most 900 remain; the capacity is enforced at startup too")
    func smallSegments() throws {
        let store = h.store()
        for i in 0..<1001 {
            _ = store.append(h.line("e\(i)"))
            store.closeOpenSegment()
        }
        #expect(store.pendingCount == 900)
        #expect(h.count(.queueFull) == 101)
        #expect(try h.ids(store, store.closedSegments()[0]) == ["e101"])

        let other = EventStoreHarness()
        for segment in 0..<12 {
            try other.write(
                String(format: "%010d", segment), (0..<100).map { other.line("s\(segment)-\($0)") + "\n" }.joined())
        }
        let restarted = other.store()
        #expect(restarted.pendingCount == 900)
        #expect(other.count(.queueFull) == 300)
    }

    @Test("a batch on its way to the server is never trimmed")
    func readingProtected() {
        let store = h.store()
        for i in 0..<1000 { _ = store.append(h.line("e\(i)")) }
        _ = store.writeBatch(index: 0, sentAt: EventStoreHarness.sentAt)

        _ = store.append(h.line("e1000"))

        #expect(store.closedSegments().contains(0))
        #expect(Array(store.closedSegments().prefix(2)) == [0, 3])
        store.deleteSegment(0)
        _ = store.append(h.line("e1001"))
        #expect(!store.closedSegments().contains(0))
    }

    @Test("clear deletes closed and open segments without counting, and indexes keep growing")
    func clear() throws {
        let store = h.store()
        for i in 0..<150 { _ = store.append(h.line("e\(i)")) }
        store.clear()
        #expect(try h.files().isEmpty)
        #expect(store.pendingCount == 0)
        #expect(store.closedSegments().isEmpty)
        #expect(h.dropped.current.isEmpty)
        _ = store.append(h.line("after"))
        store.closeOpenSegment()
        #expect(store.closedSegments() == [2])
        #expect(try h.ids(store, 2) == ["after"])
    }
}

@Suite("FileEventStore failures and the locked device")
struct FileEventStoreFailureTests {
    let h = EventStoreHarness()

    @Test("a failed write counts storage_error, logs an error and the next event goes to a new segment")
    func failedWrite() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        h.fs.failOnce(.write)

        #expect(store.append(h.line("lost")) == .failed)
        #expect(store.append(h.line("b")) == .appended)
        store.closeOpenSegment()

        #expect(h.count(.storageError) == 1)
        #expect(h.test.logger.lines.contains { $0.level == .error && $0.message.hasPrefix("STORAGE_WRITE_FAILED") })
        #expect(store.closedSegments() == [0, 1])
        #expect(try h.ids(store, 0) == ["a"])
        #expect(try h.ids(store, 1) == ["b"])
        #expect(store.pendingCount == 2)
    }

    @Test("a disk that cannot be written keeps the SDK running")
    func diskFull() {
        let store = h.store()
        h.fs.failAlways(.openAppend)
        for i in 0..<5 { #expect(store.append(h.line("e\(i)")) == .failed) }
        #expect(h.count(.storageError) == 5)
        #expect(store.pendingCount == 0)
    }

    @Test("an unreadable segment is retried and deleted after three consecutive failures; a success resets the count")
    func unreadableSegment() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        store.closeOpenSegment()
        h.fs.failAlways(.read)

        let results = (1...3).map { _ in store.writeBatch(index: 0, sentAt: EventStoreHarness.sentAt) }
        let deletions: [Bool?] = results.map { result in
            if case .unreadable(let deleted, _) = result { return deleted }
            return nil
        }
        #expect(deletions == [false, false, true])
        #expect(store.closedSegments().isEmpty)
        #expect(h.logged(.unreadableSegment))
        #expect(store.pendingCount == 0)

        h.fs.heal()
        let other = EventStoreHarness()
        let second = other.store()
        _ = second.append(other.line("a"))
        second.closeOpenSegment()
        for _ in 0..<2 {
            other.fs.failOnce(.read)
            _ = second.writeBatch(index: 0, sentAt: EventStoreHarness.sentAt)
        }
        _ = try other.body(second, 0)
        for _ in 0..<2 {
            other.fs.failOnce(.read)
            _ = second.writeBatch(index: 0, sentAt: EventStoreHarness.sentAt)
        }
        #expect(second.closedSegments() == [0])
    }

    @Test("sync makes the open segment durable and never traps")
    func sync() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        store.sync()
        h.fs.failOnce(.sync)
        store.sync()
        #expect(try h.read("0000000000.tmp") == h.line("a") + "\n")
    }

    @Test("suspend closes the handle and keeps the segment open; appends continue after it")
    func suspend() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        store.suspend()
        #expect(h.fs.calls.suffix(2) == [.sync, .openAppend] || h.fs.calls.contains(.sync))
        _ = store.append(h.line("b"))
        store.closeOpenSegment()
        #expect(try h.ids(store, 0) == ["a", "b"])
    }

    @Test("a locked device: open defers, append is locked and counts nothing, reads and closes wait")
    func locked() throws {
        let store = h.store()
        _ = store.append(h.line("a"))
        store.closeOpenSegment()
        _ = store.append(h.line("b"))
        store.suspend()
        h.fs.locked = true

        #expect(store.append(h.line("c")) == .locked)
        #expect(store.writeBatch(index: 0, sentAt: EventStoreHarness.sentAt) == .locked)
        store.closeOpenSegment()
        store.expire()
        #expect(store.closedSegments() == [0])
        #expect(h.dropped.current.isEmpty)
        #expect(!h.test.logger.lines.contains { $0.level == .error })

        let fresh = FileEventStore(root: h.root, fileSystem: h.fs)
        #expect(!fresh.open(apiKey: EventStoreHarness.key, clock: h.clock, log: h.log, drops: h.drops))

        h.fs.locked = false
        #expect(store.append(h.line("c")) == .appended)
        store.closeOpenSegment()
        #expect(try h.ids(store, 0) == ["a"])
        #expect(try h.ids(store, 1) == ["b", "c"])
        #expect(fresh.open(apiKey: EventStoreHarness.key, clock: h.clock, log: h.log, drops: h.drops))
    }
}
