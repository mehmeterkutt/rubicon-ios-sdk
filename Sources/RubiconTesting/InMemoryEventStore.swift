import Foundation
import RubiconCore

/// An `EventStore` in memory with the segment rules of Disk 1: the open segment closes at
/// `maxEventsPerSegment` events, or before an event that would take it past `maxBytesPerSegment`
/// (line plus line break, UTF-8), or when asked to. `writeBatch` writes the body of Disk 3 from the
/// stored lines as they are.
///
/// The capacity, age and corruption rules are not repeated here: they belong to `FileEventStore`,
/// and a test that needs them uses it with a temporary directory. A failed append counts
/// `storage_error` through the `DropCounter` given to `open`. The `locked` switch is the device
/// before the first unlock (iOS Disk 1): `open` fails and `append` returns `.locked`.
package final class InMemoryEventStore: EventStore, @unchecked Sendable {
    private struct State {
        var closed: [Int64: [String]] = [:]
        var open: [String] = []
        var openBytes = 0
        var nextIndex: Int64 = 0
        var unreadable: Set<Int64> = []
        var drops: DropCounter = { _, _ in }
        var failAppends = false
        var locked = false
        var syncCount = 0
        var suspendCount = 0
        var opens = 0
        var clears = 0
    }

    private let maxEventsPerSegment: Int
    private let maxBytesPerSegment: Int
    // Guarded by `state`.
    private let state = Locked(State())

    package init(maxEventsPerSegment: Int = 100, maxBytesPerSegment: Int = 512 * 1024) {
        self.maxEventsPerSegment = maxEventsPerSegment
        self.maxBytesPerSegment = maxBytesPerSegment
    }

    /// When `true`, `append` fails as a full disk would.
    package var failAppends: Bool {
        get { state.current.failAppends }
        set { state.withLock { $0.failAppends = newValue } }
    }

    /// When `true`, the device is locked: `open` returns `false` and `append` returns `.locked`.
    package var locked: Bool {
        get { state.current.locked }
        set { state.withLock { $0.locked = newValue } }
    }

    /// How many times `sync` was called.
    package var syncCount: Int { state.current.syncCount }
    /// How many times `suspend` was called.
    package var suspendCount: Int { state.current.suspendCount }
    /// How many times `open` succeeded.
    package var opens: Int { state.current.opens }
    /// How many times `clear` was called.
    package var clears: Int { state.current.clears }

    /// The lines of the open segment, for assertions.
    package var openSegment: [String] { state.current.open }

    /// The lines of a closed segment, for assertions; empty when there is none.
    package func segmentLines(_ index: Int64) -> [String] { state.current.closed[index] ?? [] }

    /// Every stored line, closed segments first in order, then the open segment.
    package var allLines: [String] {
        state.withLock { s in s.closed.keys.sorted().flatMap { s.closed[$0] ?? [] } + s.open }
    }

    package func open(apiKey: String, clock: any Clock, log: Log, drops: @escaping DropCounter) -> Bool {
        state.withLock { s in
            if s.locked { return false }
            s.drops = drops
            s.opens += 1
            return true
        }
    }

    package var pendingCount: Int {
        state.withLock { s in s.closed.values.reduce(0) { $0 + $1.count } + s.open.count }
    }

    package func append(_ line: String) -> AppendResult {
        let drops: DropCounter? = state.withLock { s in
            if s.locked { return nil }
            if s.failAppends { return s.drops }
            let bytes = line.utf8.count + 1
            if !s.open.isEmpty && s.openBytes + bytes > maxBytesPerSegment { close(&s) }
            s.open.append(line)
            s.openBytes += bytes
            if s.open.count >= maxEventsPerSegment { close(&s) }
            return nil
        }
        if let drops {
            drops(.storageError, 1)
            return .failed
        }
        return locked ? .locked : .appended
    }

    package func closeOpenSegment() {
        state.withLock { close(&$0) }
    }

    package func sync() {
        state.withLock { $0.syncCount += 1 }
    }

    package func suspend() {
        state.withLock { $0.suspendCount += 1 }
    }

    package func expire() {}

    package func closedSegments() -> [Int64] {
        state.current.closed.keys.sorted()
    }

    package func writeBatch(index: Int64, sentAt: Date) -> BatchResult {
        let lines: [String]? = state.withLock { s in
            if s.locked { return nil }
            if s.unreadable.contains(index) { return nil }
            return s.closed[index] ?? []
        }
        guard let lines else {
            if locked { return .locked }
            return .unreadable(deleted: false, cause: .io(code: EIO, operation: "read"))
        }
        let body = Data(("{\"sent_at\":\(sentAt.epochMillis),\"batch\":[" + lines.joined(separator: ",") + "]}").utf8)
        let ids = lines.map { Json.readObject($0)?.string("message_id") ?? $0 }
        return .written(messageIds: ids, body: body)
    }

    package func clear() {
        state.withLock { s in
            s.closed = [:]
            s.open = []
            s.openBytes = 0
            s.unreadable = []
            s.clears += 1
        }
    }

    package func deleteSegment(_ index: Int64) {
        state.withLock { s in
            s.closed[index] = nil
            s.unreadable.remove(index)
        }
    }

    /// Makes `writeBatch` of `index` report it unreadable, as an I/O error would (Disk 5).
    package func markUnreadable(_ index: Int64) {
        state.withLock { _ = $0.unreadable.insert(index) }
    }

    private func close(_ s: inout State) {
        if s.open.isEmpty { return }
        s.closed[s.nextIndex] = s.open
        s.nextIndex += 1
        s.open = []
        s.openBytes = 0
    }
}
