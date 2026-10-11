import Foundation
import RubiconCore

/// A `FileSystem` over real files that fails the operations the test chooses, once or always, and
/// has a `locked` switch that makes every operation fail with `permissionDenied`, the state of a
/// locked device (iOS Disk 1).
package final class FakeFileSystem: FileSystem, @unchecked Sendable {
    package enum Operation: String, CaseIterable, Sendable {
        case exists, list, createDirectory, excludeFromBackup, fileSize, read, openAppend, openWrite
        case write, sync, truncate, rename, delete
    }

    private struct Faults {
        var once: Set<Operation> = []
        var always: Set<Operation> = []
        var locked = false
        var calls: [Operation] = []
    }

    private let delegate: any FileSystem
    // Guarded by `faults`.
    private let faults = Locked(Faults())

    package init(delegate: any FileSystem = PosixFileSystem()) {
        self.delegate = delegate
    }

    /// The next call of `operation` fails; later ones succeed.
    package func failOnce(_ operation: Operation) {
        faults.withLock { $0.once.insert(operation) }
    }

    /// Every call of `operation` fails until `heal()`.
    package func failAlways(_ operation: Operation) {
        faults.withLock { $0.always.insert(operation) }
    }

    package func heal() {
        faults.withLock {
            $0.once = []
            $0.always = []
            $0.locked = false
        }
    }

    /// While `true`, every operation but `exists` fails with `permissionDenied`.
    package var locked: Bool {
        get { faults.current.locked }
        set { faults.withLock { $0.locked = newValue } }
    }

    /// Every operation called so far, in order, for assertions such as "sync was called once".
    package var calls: [Operation] {
        faults.current.calls
    }

    package func clearCalls() {
        faults.withLock { $0.calls = [] }
    }

    private func check(_ operation: Operation) throws(FileSystemError) {
        let outcome: FileSystemError? = faults.withLock { f in
            f.calls.append(operation)
            if f.locked && operation != .exists { return .permissionDenied }
            if f.always.contains(operation) || f.once.remove(operation) != nil {
                return .io(code: -1, operation: "injected:\(operation.rawValue)")
            }
            return nil
        }
        if let outcome { throw outcome }
    }

    package func exists(_ url: URL) -> Bool {
        faults.withLock { $0.calls.append(.exists) }
        return delegate.exists(url)
    }

    package func list(_ directory: URL) throws(FileSystemError) -> [URL] {
        try check(.list)
        return try delegate.list(directory)
    }

    package func createDirectory(_ directory: URL) throws(FileSystemError) {
        try check(.createDirectory)
        try delegate.createDirectory(directory)
    }

    package func excludeFromBackup(_ directory: URL) throws(FileSystemError) {
        try check(.excludeFromBackup)
        try delegate.excludeFromBackup(directory)
    }

    package func fileSize(_ url: URL) throws(FileSystemError) -> Int64 {
        try check(.fileSize)
        return try delegate.fileSize(url)
    }

    package func read(_ url: URL) throws(FileSystemError) -> Data {
        try check(.read)
        return try delegate.read(url)
    }

    package func openAppend(_ url: URL) throws(FileSystemError) -> any FileSink {
        try check(.openAppend)
        return FaultySink(sink: try delegate.openAppend(url), owner: self)
    }

    package func openWrite(_ url: URL) throws(FileSystemError) -> any FileSink {
        try check(.openWrite)
        return FaultySink(sink: try delegate.openWrite(url), owner: self)
    }

    package func truncate(_ url: URL, to length: Int64) throws(FileSystemError) {
        try check(.truncate)
        try delegate.truncate(url, to: length)
    }

    package func rename(_ from: URL, to: URL) throws(FileSystemError) {
        try check(.rename)
        try delegate.rename(from, to: to)
    }

    package func delete(_ url: URL) throws(FileSystemError) {
        try check(.delete)
        try delegate.delete(url)
    }

    // Forwards to the real sink; the owner's checks are thread-safe.
    private final class FaultySink: FileSink, @unchecked Sendable {
        private let sink: any FileSink
        private let owner: FakeFileSystem

        init(sink: any FileSink, owner: FakeFileSystem) {
            self.sink = sink
            self.owner = owner
        }

        func write(_ bytes: Data) throws(FileSystemError) {
            try owner.check(.write)
            try sink.write(bytes)
        }

        func sync() throws(FileSystemError) {
            try owner.check(.sync)
            try sink.sync()
        }

        func close() {
            sink.close()
        }
    }
}
