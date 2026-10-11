import Foundation

/// Counts dropped events by reason for `SDK Diagnostics` (Queue 5, Logging 5).
package typealias DropCounter = @Sendable (DropReason, Int) -> Void

/// What `EventStore.append` did.
package enum AppendResult: Sendable, Equatable {
    case appended
    /// Protected data is unavailable (iOS Disk 1); the event is not stored and not counted. The
    /// writer holds it until the device unlocks.
    case locked
    /// The write failed; `storage_error` was counted and logged, and the next event goes to a new
    /// segment (Disk 4).
    case failed
}

/// What `EventStore.writeBatch` produced.
package enum BatchResult: Sendable, Equatable {
    /// The body was written with `messageIds`, in order. When it is empty every line was skipped:
    /// the segment is deleted without an upload.
    case written(messageIds: [String], body: Data)
    /// The segment could not be read; `deleted` after the third consecutive failure.
    case unreadable(deleted: Bool, cause: FileSystemError)
    /// Protected data is unavailable; nothing was read, counted or deleted (iOS Disk 1).
    case locked
}

/// Pending events, as a log of segments where a closed segment is one batch (Disk 1). Only the
/// writer appends and only the uploader reads and deletes (Queue 1). Not replaceable by developers
/// (Disk 6).
///
/// The store enforces the capacity of Queue 5 and counts every event it drops through the
/// `DropCounter`: `queue_full`, `expired`, `storage_error`, `corrupt` and `api_key_changed`. The
/// uploader counts what the server rejects.
package protocol EventStore: Sendable {
    /// Startup work, the writer's first storage task and called once before anything else: deletes
    /// other keys' events, recovers a leftover open segment, deletes unknown files, counts pending
    /// events, expires old ones and enforces the capacity (Disk 2, 4, 5; Queue 5). Returns `false`
    /// while the device is locked; call again after `protectedDataDidBecomeAvailable`.
    func open(apiKey: String, clock: any Clock, log: Log, drops: @escaping DropCounter) -> Bool

    /// Events on disk, in closed segments and the open one.
    var pendingCount: Int { get }

    /// Appends one serialized event, without its line break, to the open segment, then drops the
    /// oldest segments if the capacity is passed.
    func append(_ line: String) -> AppendResult

    /// Closes the open segment so that it becomes a batch; does nothing when it is empty.
    func closeOpenSegment()

    /// Makes the open segment durable, on backgrounding (Disk 4).
    func sync()

    /// Before the device locks (iOS Disk 1): syncs the open segment and closes its file handle
    /// without closing the segment; the next `append` reopens it.
    func suspend()

    /// Deletes closed segments whose events are all older than 3 days; before every upload (Queue 5).
    func expire()

    /// Indexes of the closed segments, oldest first (Disk 2b).
    func closedSegments() -> [Int64]

    /// Builds the request body of a closed segment: `{"sent_at":..,"batch":[..]}` with the stored
    /// lines as they are, skipping corrupt and expired ones (Disk 3, 5; Serialization 5). A segment
    /// that cannot be read is retried on later calls and deleted after three consecutive failures
    /// in the process (Disk 5).
    func writeBatch(index: Int64, sentAt: Date) -> BatchResult

    /// Deletes every pending event, closed segments and the open one, without counting them: for
    /// `clearLocalData()` and for waiting events when a pending consent turns into an opt-out
    /// (Privacy 3, 4). An upload already reading a segment may still complete.
    func clear()

    /// Deletes a closed segment after the server acknowledged it or when it is dropped. The corrupt
    /// and expired lines its last `writeBatch` skipped are counted now, once.
    func deleteSegment(_ index: Int64)
}
