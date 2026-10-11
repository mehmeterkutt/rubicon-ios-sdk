import Foundation

/// `KeyValueStore` as small files in `root`, `Application Support/rubicon/` on iOS (Disk 2a, 7).
///
/// - A write replaces the whole file atomically: `{name}.tmp` is written, synced (`F_FULLFSYNC`,
///   iOS Disk 2) and renamed over `{name}`, so a reader sees the old or the new content, never a mix.
/// - A `{name}.tmp` found when `name` is first read is a write whose rename never happened; it is
///   deleted and the old file is intact. Reads and writes run on the writer only (Queue 1), so a
///   `.tmp` is never one in progress.
/// - A file that exists but cannot be read, or is not valid UTF-8, is `.unreadable`; a permission
///   error is `.locked` (iOS Disk 1).
/// - The first write marks `root` as excluded from backup (iOS Identity 1).
///
/// Never throws; a failed write or delete is reported in the result and the caller logs it.
package final class FileKeyValueStore: KeyValueStore {
    private let root: URL
    private let fileSystem: any FileSystem
    // The backup exclusion of iOS Identity 1 is set once the directory exists, once per process.
    private let excluded = AtomicFlag()

    package init(root: URL, fileSystem: any FileSystem) {
        self.root = root
        self.fileSystem = fileSystem
    }

    package func read(_ name: String) -> KeyValueRead {
        let file = root.appendingPathComponent(name)
        do {
            try discardLeftover(name)
            guard fileSystem.exists(file) else { return .missing }
            let bytes = try fileSystem.read(file)
            guard let text = String(data: bytes, encoding: .utf8) else {
                return .unreadable(.io(code: EILSEQ, operation: "utf8"))
            }
            return .present(text)
        } catch FileSystemError.permissionDenied {
            return .locked
        } catch {
            return .unreadable(error)
        }
    }

    package func write(_ name: String, content: String) -> KeyValueWrite {
        let file = root.appendingPathComponent(name)
        let tmp = tmpOf(name)
        do {
            try fileSystem.createDirectory(root)
            if !excluded.isSet {
                try fileSystem.excludeFromBackup(root)
                excluded.set()
            }
            let sink = try fileSystem.openWrite(tmp)
            defer { sink.close() }
            try sink.write(Data(content.utf8))
            try sink.sync()
            try fileSystem.rename(tmp, to: file)
            return .done
        } catch FileSystemError.permissionDenied {
            deleteQuietly(tmp)
            return .locked
        } catch {
            deleteQuietly(tmp)
            return .failed(error)
        }
    }

    package func delete(_ name: String) -> KeyValueWrite {
        do {
            try fileSystem.delete(root.appendingPathComponent(name))
            return .done
        } catch FileSystemError.permissionDenied {
            return .locked
        } catch {
            return .failed(error)
        }
    }

    private func tmpOf(_ name: String) -> URL {
        root.appendingPathComponent("\(name).tmp")
    }

    private func discardLeftover(_ name: String) throws(FileSystemError) {
        let tmp = tmpOf(name)
        if fileSystem.exists(tmp) { try fileSystem.delete(tmp) }
    }

    private func deleteQuietly(_ url: URL) {
        // The next read of the store deletes the leftover.
        try? fileSystem.delete(url)
    }
}
