import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("FakeFileSystem")
struct FakeFileSystemTests {
    let dir = TestPlatform.temporaryDirectory()
    let fs = FakeFileSystem()

    // Calls the operation once on a file that exists, so a healthy call succeeds.
    private func call(_ operation: FakeFileSystem.Operation) throws {
        let f = dir.appendingPathComponent("a")
        let sink = try PosixFileSystem().openWrite(f)
        try sink.write(Data("x".utf8))
        sink.close()
        switch operation {
        case .exists: _ = fs.exists(f)
        case .list: _ = try fs.list(dir)
        case .createDirectory: try fs.createDirectory(dir.appendingPathComponent("sub"))
        case .excludeFromBackup: try fs.excludeFromBackup(dir)
        case .fileSize: _ = try fs.fileSize(f)
        case .read: _ = try fs.read(f)
        case .openAppend: try fs.openAppend(f).close()
        case .openWrite: try fs.openWrite(f).close()
        case .write:
            let s = try fs.openAppend(f)
            defer { s.close() }
            try s.write(Data([1]))
        case .sync:
            let s = try fs.openAppend(f)
            defer { s.close() }
            try s.sync()
        case .truncate: try fs.truncate(f, to: 0)
        case .rename: try fs.rename(f, to: dir.appendingPathComponent("b"))
        case .delete: try fs.delete(f)
        }
    }

    @Test(
        "fails the next call and then succeeds", arguments: FakeFileSystem.Operation.allCases.filter { $0 != .exists })
    func failOnce(operation: FakeFileSystem.Operation) throws {
        fs.failOnce(operation)

        #expect(throws: FileSystemError.io(code: -1, operation: "injected:\(operation.rawValue)")) {
            try call(operation)
        }
        try call(operation)
    }

    @Test("fails every call until healed", arguments: FakeFileSystem.Operation.allCases.filter { $0 != .exists })
    func failAlways(operation: FakeFileSystem.Operation) throws {
        fs.failAlways(operation)

        for _ in 0..<3 {
            #expect(throws: FileSystemError.self) { try call(operation) }
        }
        fs.heal()
        try call(operation)
    }

    @Test("only the chosen operation fails")
    func onlyChosen() throws {
        fs.failAlways(.rename)
        for operation in FakeFileSystem.Operation.allCases where operation != .rename {
            try call(operation)
        }
    }

    @Test(
        "locked reports permissionDenied for every operation but exists",
        arguments: FakeFileSystem.Operation.allCases.filter { $0 != .exists })
    func locked(operation: FakeFileSystem.Operation) throws {
        fs.locked = true

        #expect(throws: FileSystemError.permissionDenied) { try call(operation) }
        fs.locked = false
        try call(operation)
    }

    @Test("exists still answers while locked, and calls are recorded in order")
    func existsWhileLocked() throws {
        fs.locked = true
        #expect(!fs.exists(dir.appendingPathComponent("nothing")))
        fs.locked = false
        fs.clearCalls()

        try call(.write)

        #expect(fs.calls == [.openAppend, .write])
    }

    @Test("when healthy it passes every operation to the real files")
    func healthy() throws {
        let a = dir.appendingPathComponent("a")
        let w = try fs.openWrite(a)
        try w.write(Data("line 1\n".utf8))
        w.close()
        let s = try fs.openAppend(a)
        try s.write(Data("line 2\n".utf8))
        try s.sync()
        s.close()

        #expect(fs.exists(a))
        #expect(try fs.fileSize(a) == 14)
        #expect(try fs.read(a) == Data("line 1\nline 2\n".utf8))
        try fs.createDirectory(dir.appendingPathComponent("sub"))
        try fs.rename(a, to: dir.appendingPathComponent("b"))
        #expect(try fs.list(dir).map(\.lastPathComponent).sorted() == ["b", "sub"])
        try fs.delete(dir.appendingPathComponent("b"))
        #expect(!fs.exists(dir.appendingPathComponent("b")))
    }
}
