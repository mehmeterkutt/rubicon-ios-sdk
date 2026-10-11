import Foundation

/// The small whole-value files behind `PersonStore`, `DeviceStore` and the remote configuration
/// cache (Disk 7), addressed by name. Only the writer writes (Queue 1). Not replaceable by
/// developers (Disk 6).
package protocol KeyValueStore: Sendable {
    /// "Missing", "unreadable" and "locked" are different results (Identity 1, iOS Disk 1).
    func read(_ name: String) -> KeyValueRead

    /// Replaces the whole value atomically.
    func write(_ name: String, content: String) -> KeyValueWrite

    /// Deletes the value; `.done` when there was none.
    func delete(_ name: String) -> KeyValueWrite
}

package enum KeyValueRead: Sendable, Equatable {
    /// Never written, or deleted.
    case missing
    /// Present but not readable (corrupt, a newer format); never overwrite it.
    case unreadable(FileSystemError)
    /// Protected data is unavailable (iOS Disk 1): try again after the device unlocks; never
    /// overwrite, never mint a temporary id, never count.
    case locked
    case present(String)
}

package enum KeyValueWrite: Sendable, Equatable {
    case done
    /// Protected data is unavailable; the value is kept in memory and written later.
    case locked
    /// A full disk or another I/O failure; logged as `STORAGE_WRITE_FAILED`.
    case failed(FileSystemError)
}
