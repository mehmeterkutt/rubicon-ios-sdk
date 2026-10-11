import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("PosixFileSystem")
struct PosixFileSystemTests {
    let dir = TestPlatform.temporaryDirectory()
    let fs = PosixFileSystem()

    @Test("append adds to the end and creates the file; write replaces")
    func appendAndWrite() throws {
        let file = dir.appendingPathComponent("0000000000.tmp")

        let a = try fs.openAppend(file)
        try a.write(Data("a\n".utf8))
        a.close()
        let b = try fs.openAppend(file)
        try b.write(Data("b\n".utf8))
        try b.sync()
        b.close()
        #expect(try fs.read(file) == Data("a\nb\n".utf8))
        #expect(try fs.fileSize(file) == 4)

        let w = try fs.openWrite(file)
        try w.write(Data("new".utf8))
        try w.sync()
        w.close()
        #expect(try fs.read(file) == Data("new".utf8))
    }

    @Test("a missing file is notFound, not an I/O error")
    func missing() {
        let missing = dir.appendingPathComponent("missing")
        #expect(!fs.exists(missing))
        #expect(throws: FileSystemError.notFound) { try fs.read(missing) }
        #expect(throws: FileSystemError.notFound) { try fs.fileSize(missing) }
        #expect(throws: FileSystemError.notFound) { try fs.openAppend(dir.appendingPathComponent("no/such/dir/file")) }
    }

    @Test("rename replaces the target atomically")
    func rename() throws {
        let tmp = dir.appendingPathComponent("device.json.tmp")
        let target = dir.appendingPathComponent("device.json")
        try write("new", to: tmp)
        try write("old", to: target)

        try fs.rename(tmp, to: target)

        #expect(try fs.read(target) == Data("new".utf8))
        #expect(!fs.exists(tmp))
    }

    @Test("list, createDirectory, truncate and delete")
    func directories() throws {
        let events = dir.appendingPathComponent("events/v1/abc", isDirectory: true)

        #expect(try fs.list(events).isEmpty)
        try fs.createDirectory(events)
        try fs.createDirectory(events)
        let file = events.appendingPathComponent("0000000001")
        try write("xyz", to: file)

        #expect(try fs.list(events).map(\.lastPathComponent) == ["0000000001"])
        try fs.truncate(file, to: 1)
        #expect(try fs.read(file) == Data("x".utf8))
        try fs.delete(file)
        try fs.delete(file)
        #expect(!fs.exists(file))
    }

    @Test("delete removes an empty directory too, and a missing one is fine")
    func deleteDirectory() throws {
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try fs.createDirectory(sub)
        try fs.delete(sub)
        #expect(!fs.exists(sub))
        try fs.delete(sub)
    }

    @Test("excludeFromBackup sets the resource value on the directory")
    func backupExclusion() throws {
        let sub = dir.appendingPathComponent("rubicon", isDirectory: true)
        try fs.createDirectory(sub)

        try fs.excludeFromBackup(sub)

        let values = try sub.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test("a closed sink can be closed again without harm")
    func doubleClose() throws {
        let sink = try fs.openWrite(dir.appendingPathComponent("x"))
        sink.close()
        sink.close()
    }

    private func write(_ text: String, to url: URL) throws {
        let sink = try fs.openWrite(url)
        try sink.write(Data(text.utf8))
        sink.close()
    }
}

@Suite("PosixFileSystem failures")
struct PosixFileSystemFailureTests {
    let dir = TestPlatform.temporaryDirectory()
    let fs = PosixFileSystem()

    @Test("operations on a missing file report notFound")
    func missingFile() {
        let missing = dir.appendingPathComponent("missing")
        #expect(throws: FileSystemError.notFound) { try fs.truncate(missing, to: 0) }
        #expect(throws: FileSystemError.notFound) { try fs.rename(missing, to: dir.appendingPathComponent("b")) }
        #expect(throws: FileSystemError.notFound) { try fs.excludeFromBackup(missing) }
    }

    @Test("a file where a directory is expected lists nothing and cannot hold children")
    func notADirectory() throws {
        let file = dir.appendingPathComponent("file")
        let sink = try fs.openWrite(file)
        sink.close()

        #expect(try fs.list(file).isEmpty)
        #expect(throws: FileSystemError.self) { try fs.createDirectory(file.appendingPathComponent("sub")) }
    }

    @Test("a directory without write permission gives permissionDenied, the locked-device shape")
    func permissionDenied() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try fs.createDirectory(locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }

        #expect(throws: FileSystemError.permissionDenied) { try fs.openAppend(locked.appendingPathComponent("x")) }
        #expect(throws: FileSystemError.permissionDenied) {
            try fs.createDirectory(locked.appendingPathComponent("sub"))
        }
    }

    @Test("the fsync fallback flag starts clear")
    func fallbackFlag() {
        #expect(!fs.usesFsyncFallback)
    }
}

@Suite("Atomic helpers")
struct AtomicHelpersTests {
    @Test("the flag reports which caller flipped it, and clears")
    func flag() {
        let flag = AtomicFlag()
        #expect(flag.set())
        #expect(!flag.set())
        #expect(flag.isSet)
        #expect(flag.clear())
        #expect(!flag.clear())
        #expect(!flag.isSet)
    }

    @Test("a network failure describes its kind and cause")
    func failureDescription() {
        let result = HttpResult.networkFailure(kind: .tls, cause: URLError(.secureConnectionFailed))
        #expect(result.description.hasPrefix("NetworkFailure(tls, "))
    }
}
