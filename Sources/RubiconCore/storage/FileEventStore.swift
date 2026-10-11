import Foundation

/// The `EventStore` of Disk 1 to 5: a segmented append log under `{root}/events/v1/{keyHash}/`
/// (iOS Disk 3), a port of the Android `FileEventStore`.
///
/// - The open segment is `{index}.tmp`, written with one `write()` per line and kept open. It
///   closes at `maxEvents` events, before a line that would take it past `maxBytes`, or on request:
///   synced (`F_FULLFSYNC`), then renamed to `{index}`. A closed segment is never modified and is
///   one batch.
/// - Indexes are ten digits, so name order is numeric order; the next one is the largest in the
///   directory plus one (Disk 2b). No file date is ever read; sizes are what the writer wrote.
/// - Only `events/v1/` is touched: a later format in `events/v2/` survives a downgrade.
/// - The writer appends and closes; the uploader expires, reads and deletes. Bookkeeping is behind
///   one lock; file work on a closed segment runs outside it.
/// - A permission error is the locked device (iOS Disk 1): nothing is counted or deleted, and the
///   caller tries again after the unlock.
package final class FileEventStore: EventStore, @unchecked Sendable {
    /// Events per segment, and so per batch (Queue 4).
    package static let maxEvents = 100
    /// Bytes per segment, lines and line breaks before compression (Queue 4).
    package static let maxBytes: Int64 = 512 * 1024
    /// Pending events allowed, and the count trimming goes down to (Queue 5).
    package static let maxPending = 1000
    package static let trimTo = 900
    /// Events older than this are deleted unsent (Queue 5).
    package static let maxAgeMillis: Int64 = 3 * 24 * 60 * 60 * 1000
    /// Consecutive read failures before a segment is deleted (Disk 5).
    package static let maxReadFailures = 3

    private static let eventsDir = "events"
    private static let formatDir = "v1"
    private static let keyHashLength = 16
    private static let indexWidth = 10
    private static let tmp = ".tmp"

    private struct Skipped {
        var corrupt: Int
        var expired: Int
    }

    private struct OpenSegment {
        var index: Int64
        var sink: (any FileSink)?
        var count: Int
        var bytes: Int64
    }

    private struct State {
        // Closed segment index to its line count, oldest first.
        var closed: [Int64: Int] = [:]
        var total = 0
        var nextIndex: Int64 = 0
        // The segment the uploader is sending: from its writeBatch until it is deleted or the next
        // batch is read, so trimming never deletes a batch that is on its way.
        var reading: Int64?
        var open: OpenSegment?
        // Uploader bookkeeping: consecutive read failures, and what the last read of a segment skipped.
        var readFailures: [Int64: Int] = [:]
        var skipped: [Int64: Skipped] = [:]
        var corruptReported: Set<Int64> = []
        var opened = false
    }

    private let root: URL
    private let fileSystem: any FileSystem
    // Guarded by `state`; file work on closed segments runs outside the lock.
    private let state = Locked(State())
    private struct Setup {
        var dir: URL
        var clock: any Clock
        var log: Log
        var drops: DropCounter
    }

    // Set by `open`, read afterwards; never changed again.
    private let setup = Locked<Setup?>(nil)

    package init(root: URL, fileSystem: any FileSystem) {
        self.root = root
        self.fileSystem = fileSystem
    }

    private var dir: URL { setup.current?.dir ?? root }
    private var clock: any Clock { setup.current?.clock ?? UnopenedClock() }
    private var log: Log { setup.current?.log ?? Log(level: .off, logger: nil, platformLogger: noOpLogger) }
    private var drops: DropCounter {
        if let drops = setup.current?.drops { return drops }
        return { _, _ in }
    }

    private struct UnopenedClock: Clock {
        func now() -> Date { Date(epochMillis: 0) }
    }

    package var pendingCount: Int { state.current.total }

    package func open(apiKey: String, clock: any Clock, log: Log, drops: @escaping DropCounter) -> Bool {
        let keyHash = String(Hashing.sha256Hex(apiKey).prefix(Self.keyHashLength))
        let formatDir = root.appendingPathComponent(Self.eventsDir, isDirectory: true).appendingPathComponent(
            Self.formatDir, isDirectory: true)
        let dir = formatDir.appendingPathComponent(keyHash, isDirectory: true)
        setup.withLock { $0 = Setup(dir: dir, clock: clock, log: log, drops: drops) }
        do {
            try fileSystem.createDirectory(dir)
            try deleteOtherKeys(formatDir, keyHash: keyHash)
            try scanOwnDirectory()
        } catch FileSystemError.permissionDenied {
            log.debug {
                "The event directory cannot be prepared while the device is locked; waiting for protected data"
            }
            state.withLock { s in
                s.closed = [:]
                s.total = 0
            }
            return false
        } catch {
            log.error(.storageWriteFailed, error) { "Could not prepare the event directory" }
        }
        state.withLock { $0.opened = true }
        expire()
        trimToCapacity()
        return true
    }

    package func append(_ line: String) -> AppendResult {
        let bytes = Data((line + "\n").utf8)
        if let open = state.current.open, open.bytes + Int64(bytes.count) > Self.maxBytes { closeOpenSegment() }
        do {
            let sink = try sinkForAppend()
            try sink.write(bytes)
        } catch FileSystemError.permissionDenied {
            releaseOpenHandle()
            log.debug { "Could not write an event while the device is locked; it waits" }
            return .locked
        } catch {
            abandonOpenSegment()
            drops(.storageError, 1)
            log.error(.storageWriteFailed, error) { "Could not write an event; it was dropped" }
            return .failed
        }
        let full: Bool = state.withLock { s in
            s.open?.count += 1
            s.open?.bytes += Int64(bytes.count)
            s.total += 1
            return (s.open?.count ?? 0) >= Self.maxEvents
        }
        if full { closeOpenSegment() }
        trimToCapacity()
        return .appended
    }

    package func closeOpenSegment() {
        let open: OpenSegment? = state.withLock { s in
            guard let open = s.open, open.count > 0 || open.sink != nil else { return nil }
            s.open = nil
            return open
        }
        guard let open else { return }
        if open.count == 0 {
            open.sink?.close()
            try? fileSystem.delete(tmpFile(open.index))
            return
        }
        do {
            let sink = try open.sink ?? fileSystem.openAppend(tmpFile(open.index))
            defer { sink.close() }
            try sink.sync()
            try fileSystem.rename(tmpFile(open.index), to: segmentFile(open.index))
            state.withLock { $0.closed[open.index] = open.count }
            log.debug { "Closed segment \(name(open.index)) with \(open.count) events" }
        } catch FileSystemError.permissionDenied {
            // The device locked mid-way: keep the segment open and reopen it after the unlock.
            state.withLock { $0.open = OpenSegment(index: open.index, sink: nil, count: open.count, bytes: open.bytes) }
            log.debug { "Could not close segment \(name(open.index)) while the device is locked; it stays open" }
        } catch {
            // The .tmp stays and is recovered by the next process; its events leave this one's count.
            state.withLock { $0.total -= open.count }
            log.error(.storageWriteFailed, error) {
                "Could not close segment \(name(open.index)); it is recovered at the next start"
            }
        }
    }

    package func sync() {
        guard let sink = state.current.open?.sink else { return }
        do {
            try sink.sync()
        } catch {
            log.debug { "Could not sync the open segment: \(error)" }
        }
    }

    package func suspend() {
        sync()
        releaseOpenHandle()
    }

    package func expire() {
        let now = clock.now().epochMillis
        for index in closedSegments() {
            if state.current.reading == index { continue }
            // An unreadable segment is left to writeBatch, which retries and deletes it.
            guard let scan = try? scan(index, now: now) else { continue }
            if scan.live == 0 && scan.expired > 0 {
                let report: Bool = state.withLock { s in
                    s.skipped[index] = Skipped(corrupt: scan.corrupt, expired: scan.expired)
                    return scan.corrupt > 0 && s.corruptReported.insert(index).inserted
                }
                if report {
                    log.error(.corruptLine) {
                        "Skipped \(scan.corrupt) corrupt lines of expired segment \(name(index))"
                    }
                }
                deleteSegment(index)
            }
        }
    }

    package func closedSegments() -> [Int64] {
        state.current.closed.keys.sorted()
    }

    package func writeBatch(index: Int64, sentAt: Date) -> BatchResult {
        let present: Bool = state.withLock { s in
            guard s.closed[index] != nil else { return false }
            s.reading = index
            return true
        }
        guard present else { return .written(messageIds: [], body: Data()) }
        let now = clock.now().epochMillis
        let reportCorrupt: Bool = state.withLock { $0.corruptReported.insert(index).inserted }
        do {
            var body = Data("{\"sent_at\":\(sentAt.epochMillis),\"batch\":[".utf8)
            var ids: [String] = []
            var corrupt = 0
            var expired = 0
            try forEachLine(segmentFile(index)) { number, line in
                guard let parsed = parse(line) else {
                    corrupt += 1
                    if reportCorrupt { reportCorruptLine(index, number: number, line: line) }
                    return
                }
                if isExpired(parsed.timestamp, now: now) {
                    expired += 1
                } else {
                    if !ids.isEmpty { body.append(UInt8(ascii: ",")) }
                    body.append(line)
                    ids.append(parsed.messageId)
                }
            }
            body.append(contentsOf: "]}".utf8)
            state.withLock { s in
                s.readFailures[index] = nil
                s.skipped[index] = Skipped(corrupt: corrupt, expired: expired)
            }
            return .written(messageIds: ids, body: body)
        } catch FileSystemError.permissionDenied {
            state.withLock { s in
                _ = s.corruptReported.remove(index)
                s.reading = nil
            }
            log.debug { "Could not read segment \(name(index)) while the device is locked" }
            return .locked
        } catch {
            let failures: Int = state.withLock { s in
                _ = s.corruptReported.remove(index)
                let n = (s.readFailures[index] ?? 0) + 1
                s.readFailures[index] = n
                return n
            }
            if failures < Self.maxReadFailures {
                log.debug { "Could not read segment \(name(index)) (attempt \(failures)): \(error)" }
                return .unreadable(deleted: false, cause: error)
            }
            log.error(.unreadableSegment, error) {
                "Segment \(name(index)) could not be read \(failures) times; it was deleted"
            }
            state.withLock { $0.skipped[index] = nil }
            deleteSegment(index)
            return .unreadable(deleted: true, cause: error)
        }
    }

    package func clear() {
        let open: OpenSegment? = state.withLock { s in
            defer { s.open = nil }
            return s.open
        }
        open?.sink?.close()
        let deleted: Int = state.withLock { s in
            let count = s.closed.count
            s.closed = [:]
            s.reading = nil
            s.total = 0
            s.readFailures = [:]
            s.skipped = [:]
            s.corruptReported = []
            return count
        }
        // Every file of this key, the open segment included; indexes keep growing.
        do {
            for file in try fileSystem.list(dir) { deleteQuietly(file) }
        } catch {
            log.debug { "Could not list the event directory: \(error)" }
        }
        log.debug { "Deleted \(deleted) segments and the open one" }
    }

    package func deleteSegment(_ index: Int64) {
        let removed: (count: Int, skipped: Skipped?)? = state.withLock { s in
            if s.reading == index { s.reading = nil }
            guard let count = s.closed.removeValue(forKey: index) else { return nil }
            s.total -= count
            s.readFailures[index] = nil
            _ = s.corruptReported.remove(index)
            let skipped = s.skipped.removeValue(forKey: index)
            return (count, skipped)
        }
        guard let removed else { return }
        deleteQuietly(segmentFile(index))
        if let skipped = removed.skipped {
            if skipped.corrupt > 0 { drops(.corrupt, skipped.corrupt) }
            if skipped.expired > 0 {
                drops(.expired, skipped.expired)
                log.warn(.eventsExpired) { "Deleted \(skipped.expired) events older than 3 days without sending them" }
            }
        }
        log.debug { "Deleted segment \(name(index)) (\(removed.count) lines)" }
    }

    // MARK: - Startup

    private func deleteOtherKeys(_ formatDir: URL, keyHash: String) throws(FileSystemError) {
        var events = 0
        for other in try fileSystem.list(formatDir) where other.lastPathComponent != keyHash {
            events += try deleteTree(other)
        }
        if events > 0 {
            drops(.apiKeyChanged, events)
            log.warn(.apiKeyChanged) { "Deleted \(events) events tracked with another API key" }
        }
    }

    /// Deletes `url` and everything under it; returns the event lines it held, as far as readable.
    private func deleteTree(_ url: URL) throws(FileSystemError) -> Int {
        let children = try fileSystem.list(url)
        var events = 0
        if children.isEmpty {
            events = countLinesQuietly(url)
        } else {
            for child in children { events += try deleteTree(child) }
        }
        try fileSystem.delete(url)
        return events
    }

    private func scanOwnDirectory() throws(FileSystemError) {
        var leftovers: [Int64] = []
        var maxIndex: Int64 = -1
        for file in try fileSystem.list(dir) {
            let fileName = file.lastPathComponent
            if let index = Self.segmentIndex(fileName) {
                maxIndex = max(maxIndex, index)
                let count = countLinesQuietly(file)
                state.withLock { s in
                    s.closed[index] = count
                    s.total += count
                }
            } else if let index = Self.openSegmentIndex(fileName) {
                maxIndex = max(maxIndex, index)
                leftovers.append(index)
            } else {
                _ = try deleteTree(file)
                log.warn(.unknownFile) { "Deleted an unknown file in the events directory: \(fileName)" }
            }
        }
        state.withLock { $0.nextIndex = maxIndex + 1 }
        for index in leftovers.sorted() { try recoverLeftover(index) }
    }

    /// Keeps the complete lines of a `.tmp` left by an earlier process and closes it (Disk 4).
    private func recoverLeftover(_ index: Int64) throws(FileSystemError) {
        let tmp = tmpFile(index)
        do {
            let scan = try scanBytes(tmp)
            if scan.halfLine {
                drops(.corrupt, 1)
                log.error(.corruptLine) { "Dropped a half-written last line of segment \(name(index))" }
            }
            if scan.lines == 0 {
                try fileSystem.delete(tmp)
                return
            }
            if scan.halfLine { try fileSystem.truncate(tmp, to: scan.completeBytes) }
            let sink = try fileSystem.openAppend(tmp)
            defer { sink.close() }
            try sink.sync()
            // A closed segment of the same index cannot normally exist; never overwrite one.
            let target: Int64 =
                fileSystem.exists(segmentFile(index))
                ? state.withLock { s in
                    defer { s.nextIndex += 1 }
                    return s.nextIndex
                } : index
            try fileSystem.rename(tmp, to: segmentFile(target))
            state.withLock { s in
                s.closed[target] = scan.lines
                s.total += scan.lines
            }
            log.debug { "Recovered segment \(name(index)) with \(scan.lines) events" }
        } catch FileSystemError.permissionDenied {
            throw FileSystemError.permissionDenied
        } catch {
            log.error(.storageWriteFailed, error) {
                "Could not recover segment \(name(index)); it is tried again at the next start"
            }
        }
    }

    // MARK: - Capacity

    private func trimToCapacity() {
        let victims: [(Int64, Int)] = state.withLock { s in
            guard s.total > Self.maxPending else { return [] }
            var victims: [(Int64, Int)] = []
            var remaining = s.total
            for index in s.closed.keys.sorted() {
                if remaining <= Self.trimTo { break }
                if index == s.reading { continue }
                let count = s.closed[index] ?? 0
                victims.append((index, count))
                remaining -= count
            }
            for (index, count) in victims {
                s.closed[index] = nil
                s.total -= count
            }
            return victims
        }
        guard !victims.isEmpty else { return }
        for (index, _) in victims { deleteQuietly(segmentFile(index)) }
        let dropped = victims.reduce(0) { $0 + $1.1 }
        drops(.queueFull, dropped)
        log.warn(.queueFull) { "More than \(Self.maxPending) events were pending; dropped the oldest \(dropped)" }
    }

    // MARK: - Writing

    private func sinkForAppend() throws(FileSystemError) -> any FileSink {
        if let open = state.current.open {
            if let sink = open.sink { return sink }
            // Reopened after a suspend: the counts are still right.
            let sink = try fileSystem.openAppend(tmpFile(open.index))
            state.withLock { $0.open?.sink = sink }
            return sink
        }
        let index: Int64 = state.withLock { s in
            defer { s.nextIndex += 1 }
            return s.nextIndex
        }
        let sink = try fileSystem.openAppend(tmpFile(index))
        state.withLock { $0.open = OpenSegment(index: index, sink: sink, count: 0, bytes: 0) }
        return sink
    }

    /// Closes the open segment's handle, keeping the segment open for a later append.
    private func releaseOpenHandle() {
        let sink: (any FileSink)? = state.withLock { s in
            defer { s.open?.sink = nil }
            return s.open?.sink
        }
        sink?.close()
    }

    /// After a failed write: keeps the lines written before it as a closed segment if possible.
    private func abandonOpenSegment() {
        let open: OpenSegment? = state.withLock { s in
            defer { s.open = nil }
            return s.open
        }
        guard let open else { return }
        open.sink?.close()
        do {
            if open.count == 0 {
                try fileSystem.delete(tmpFile(open.index))
                return
            }
            try fileSystem.truncate(tmpFile(open.index), to: open.bytes)
            let sink = try fileSystem.openAppend(tmpFile(open.index))
            defer { sink.close() }
            try sink.sync()
            try fileSystem.rename(tmpFile(open.index), to: segmentFile(open.index))
            state.withLock { $0.closed[open.index] = open.count }
        } catch {
            // The .tmp stays and is recovered by the next process.
            state.withLock { $0.total -= open.count }
        }
    }

    // MARK: - Reading

    private struct Parsed {
        var messageId: String
        var timestamp: Int64
    }

    /// A line that is a JSON object with `type`, `message_id` and a whole-number `timestamp` (Disk 5).
    private func parse(_ line: Data) -> Parsed? {
        guard let fields = Json.readObject(String(decoding: line, as: UTF8.self)), fields.string("type") != nil,
            let messageId = fields.string("message_id"), let timestamp = fields.int64("timestamp")
        else { return nil }
        return Parsed(messageId: messageId, timestamp: timestamp)
    }

    private func isExpired(_ timestamp: Int64, now: Int64) -> Bool {
        now - timestamp > Self.maxAgeMillis
    }

    private struct Scan {
        var live: Int
        var expired: Int
        var corrupt: Int
    }

    private func scan(_ index: Int64, now: Int64) throws(FileSystemError) -> Scan {
        var scan = Scan(live: 0, expired: 0, corrupt: 0)
        try forEachLine(segmentFile(index)) { _, line in
            guard let parsed = parse(line) else {
                scan.corrupt += 1
                return
            }
            if isExpired(parsed.timestamp, now: now) { scan.expired += 1 } else { scan.live += 1 }
        }
        return scan
    }

    private func reportCorruptLine(_ index: Int64, number: Int, line: Data) {
        // Only the message id, never the content (Disk 5, Logging 4a).
        let id =
            Json.readObject(String(decoding: line, as: UTF8.self))?.string("message_id").map { ", message_id \($0)" }
            ?? ""
        log.error(.corruptLine) { "Skipped corrupt line \(number) of segment \(name(index))\(id)" }
    }

    /// The lines of a segment, without their line breaks; a segment is at most 512 KB.
    private func forEachLine(_ file: URL, _ action: (Int, Data) -> Void) throws(FileSystemError) {
        let data = try fileSystem.read(file)
        var number = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            number += 1
            action(number, data[start..<end])
            start = end < data.endIndex ? data.index(after: end) : end
        }
    }

    private struct ByteScan {
        var lines: Int
        var completeBytes: Int64
        var halfLine: Bool
    }

    private func scanBytes(_ file: URL) throws(FileSystemError) -> ByteScan {
        let data = try fileSystem.read(file)
        var lines = 0
        var lastLineEnd = 0
        for (offset, byte) in data.enumerated() where byte == UInt8(ascii: "\n") {
            lines += 1
            lastLineEnd = offset + 1
        }
        return ByteScan(lines: lines, completeBytes: Int64(lastLineEnd), halfLine: data.count > lastLineEnd)
    }

    private func countLinesQuietly(_ file: URL) -> Int {
        (try? scanBytes(file).lines) ?? 0
    }

    private func deleteQuietly(_ file: URL) {
        do {
            try fileSystem.delete(file)
        } catch {
            log.debug { "Could not delete \(file.lastPathComponent): \(error)" }
        }
    }

    private func name(_ index: Int64) -> String {
        let digits = String(index)
        return String(repeating: "0", count: max(0, Self.indexWidth - digits.count)) + digits
    }

    private func segmentFile(_ index: Int64) -> URL { dir.appendingPathComponent(name(index)) }
    private func tmpFile(_ index: Int64) -> URL { dir.appendingPathComponent(name(index) + Self.tmp) }

    private static func segmentIndex(_ fileName: String) -> Int64? {
        guard fileName.count == indexWidth, fileName.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int64(fileName)
    }

    private static func openSegmentIndex(_ fileName: String) -> Int64? {
        guard fileName.hasSuffix(tmp) else { return nil }
        return segmentIndex(String(fileName.dropLast(tmp.count)))
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
