import Foundation

/// Why a file operation failed. `permissionDenied` is the locked-device state of iOS Disk 1, never
/// "unreadable"; everything else is an I/O failure the stores handle as decided.
package enum FileSystemError: Error, Equatable, Sendable {
    case notFound
    /// `EPERM` or `EACCES`: protected data is unavailable (iOS Disk 1), or an injected lock.
    case permissionDenied
    case io(code: Int32, operation: String)
}

/// An open file being written (Disk 4).
package protocol FileSink: AnyObject, Sendable {
    func write(_ bytes: Data) throws(FileSystemError)

    /// Forces written bytes to the storage device: `F_FULLFSYNC`, with `fsync` as the fallback
    /// once per process (iOS Disk 2).
    func sync() throws(FileSystemError)

    func close()
}

/// The file operations the file-based stores use (Disk 6). It exists so that tests can inject
/// failures and the locked state; production is `PosixFileSystem`. Paths are URLs; the stores never
/// touch the disk any other way. `fileSize` is the one metadata read, done once at startup (iOS
/// Disk 3); it is implemented without `stat`, so the core calls no required-reason API.
package protocol FileSystem: Sendable {
    func exists(_ url: URL) -> Bool

    /// The entries of `directory`, in no particular order; empty when it does not exist.
    func list(_ directory: URL) throws(FileSystemError) -> [URL]

    /// Creates `directory` and its parents; succeeds when it already exists.
    func createDirectory(_ directory: URL) throws(FileSystemError)

    /// Marks `directory` so that backups never copy it (iOS Identity 1).
    func excludeFromBackup(_ directory: URL) throws(FileSystemError)

    /// The size of `url` in bytes.
    func fileSize(_ url: URL) throws(FileSystemError) -> Int64

    /// The whole content of a small file (the stores of Disk 7).
    func read(_ url: URL) throws(FileSystemError) -> Data

    /// Opens `url` for appending, creating it if needed.
    func openAppend(_ url: URL) throws(FileSystemError) -> any FileSink

    /// Opens `url` for writing from the start, replacing its content.
    func openWrite(_ url: URL) throws(FileSystemError) -> any FileSink

    /// Cuts `url` to its first `length` bytes, to drop a half-written last line (Disk 4).
    func truncate(_ url: URL, to length: Int64) throws(FileSystemError)

    /// Renames `from` over `to`, replacing it atomically.
    func rename(_ from: URL, to: URL) throws(FileSystemError)

    /// Deletes `url`; succeeds when it does not exist.
    func delete(_ url: URL) throws(FileSystemError)
}

/// The production file system over POSIX descriptors (`open`, `write`, `fcntl`, `rename`), so the
/// sync call has a descriptor to act on (iOS Disk 2).
package final class PosixFileSystem: FileSystem {
    // Set once, when F_FULLFSYNC first fails on this file system (the simulator, some volumes).
    private let fullSyncUnsupported = AtomicFlag()

    package init() {}

    package func exists(_ url: URL) -> Bool {
        access(url.path, F_OK) == 0
    }

    package func list(_ directory: URL) throws(FileSystemError) -> [URL] {
        guard let dir = opendir(directory.path) else {
            // A missing directory, or a file where a directory was expected, has no entries.
            if errno == ENOENT || errno == ENOTDIR { return [] }
            throw Self.error(errno, "opendir")
        }
        defer { closedir(dir) }
        var urls: [URL] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            urls.append(directory.appendingPathComponent(name))
        }
        return urls
    }

    package func createDirectory(_ directory: URL) throws(FileSystemError) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw Self.error(from: error, "mkdir")
        }
    }

    package func excludeFromBackup(_ directory: URL) throws(FileSystemError) {
        // Foundation reports a missing directory as an unknown write error without a POSIX cause.
        guard exists(directory) else { throw .notFound }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        do {
            try url.setResourceValues(values)
        } catch {
            throw Self.error(from: error, "setResourceValues")
        }
    }

    package func fileSize(_ url: URL) throws(FileSystemError) -> Int64 {
        let fd = try Self.open(url, O_RDONLY, "open")
        defer { Darwin.close(fd) }
        let end = lseek(fd, 0, SEEK_END)
        if end < 0 { throw Self.error(errno, "lseek") }
        return Int64(end)
    }

    package func read(_ url: URL) throws(FileSystemError) -> Data {
        let fd = try Self.open(url, O_RDONLY, "open")
        defer { Darwin.close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw Self.error(errno, "read")
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    package func openAppend(_ url: URL) throws(FileSystemError) -> any FileSink {
        PosixSink(fd: try Self.open(url, O_WRONLY | O_APPEND | O_CREAT, "open"), owner: self)
    }

    package func openWrite(_ url: URL) throws(FileSystemError) -> any FileSink {
        PosixSink(fd: try Self.open(url, O_WRONLY | O_TRUNC | O_CREAT, "open"), owner: self)
    }

    package func truncate(_ url: URL, to length: Int64) throws(FileSystemError) {
        if Darwin.truncate(url.path, off_t(length)) != 0 { throw Self.error(errno, "truncate") }
    }

    package func rename(_ from: URL, to: URL) throws(FileSystemError) {
        if Darwin.rename(from.path, to.path) != 0 { throw Self.error(errno, "rename") }
    }

    package func delete(_ url: URL) throws(FileSystemError) {
        if unlink(url.path) == 0 || errno == ENOENT { return }
        let unlinkError = errno
        // A directory: `unlink` refuses it with EPERM or EISDIR; `rmdir` removes an empty one.
        if unlinkError == EPERM || unlinkError == EISDIR {
            if rmdir(url.path) == 0 || errno == ENOENT { return }
            if errno != ENOTDIR { throw Self.error(errno, "rmdir") }
        }
        throw Self.error(unlinkError, "unlink")
    }

    // MARK: - Helpers

    private static func open(_ url: URL, _ flags: Int32, _ operation: String) throws(FileSystemError)
        -> Int32
    {
        let fd = Darwin.open(url.path, flags, 0o600)
        if fd < 0 { throw error(errno, operation) }
        return fd
    }

    fileprivate static func error(_ code: Int32, _ operation: String) -> FileSystemError {
        switch code {
        case ENOENT: return .notFound
        case EPERM, EACCES: return .permissionDenied
        default: return .io(code: code, operation: operation)
        }
    }

    private static func error(from error: any Error, _ operation: String) -> FileSystemError {
        let nsError = error as NSError
        // Foundation wraps the POSIX cause; the cause is the precise answer when it is there.
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return Self.error(Int32(underlying.code), operation)
        }
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .notFound
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError: return .permissionDenied
            default: break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain { return Self.error(Int32(nsError.code), operation) }
        return .io(code: Int32(clamping: nsError.code), operation: operation)
    }

    // The descriptor is used only by the sink's own methods, which the writer calls from one queue.
    private final class PosixSink: FileSink, @unchecked Sendable {
        private var fd: Int32
        private let owner: PosixFileSystem

        init(fd: Int32, owner: PosixFileSystem) {
            self.fd = fd
            self.owner = owner
        }

        func write(_ bytes: Data) throws(FileSystemError) {
            var offset = 0
            let total = bytes.count
            while offset < total {
                let written = bytes.withUnsafeBytes { raw -> Int in
                    Darwin.write(fd, raw.baseAddress.map { $0 + offset }, total - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw PosixFileSystem.error(errno, "write")
                }
                offset += written
            }
        }

        func sync() throws(FileSystemError) {
            if !owner.fullSyncUnsupported.isSet {
                if fcntl(fd, F_FULLFSYNC) == 0 { return }
                owner.fullSyncUnsupported.set()
            }
            if fsync(fd) != 0 { throw PosixFileSystem.error(errno, "fsync") }
        }

        func close() {
            if fd >= 0 {
                Darwin.close(fd)
                fd = -1
            }
        }

        deinit {
            close()
        }
    }
}

extension PosixFileSystem {
    /// `true` once `F_FULLFSYNC` failed on this file system and `fsync` is used instead; the
    /// writer logs it once at DEBUG (iOS Disk 2).
    package var usesFsyncFallback: Bool { fullSyncUnsupported.isSet }
}
