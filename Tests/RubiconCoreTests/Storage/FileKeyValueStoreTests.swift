import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("FileKeyValueStore")
struct FileKeyValueStoreTests {
    let test = TestPlatform()
    var root: URL { test.storageRoot.appendingPathComponent("rubicon", isDirectory: true) }
    var store: FileKeyValueStore { FileKeyValueStore(root: root, fileSystem: test.fileSystem) }

    private func content(_ read: KeyValueRead) -> String? {
        if case .present(let text) = read { return text }
        return nil
    }

    @Test("a store never written is missing; a write creates the directory and reads back")
    func readAndWrite() {
        #expect(store.read("device.json") == .missing)
        #expect(store.write("device.json", content: #"{"v":1}"#) == .done)
        #expect(content(store.read("device.json")) == #"{"v":1}"#)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("device.json").path))
    }

    @Test("a write replaces the whole value and leaves no tmp file; non-ASCII survives")
    func replace() throws {
        _ = store.write("person.json", content: "a much longer first value")
        _ = store.write("person.json", content: "short")
        #expect(content(store.read("person.json")) == "short")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["person.json"])
        _ = store.write("person.json", content: "Ödeme şöyle 💳")
        #expect(content(store.read("person.json")) == "Ödeme şöyle 💳")
    }

    @Test("delete removes the value and is fine when there is none")
    func delete() {
        _ = store.write("remote-config.json", content: "{}")
        #expect(store.delete("remote-config.json") == .done)
        #expect(store.delete("remote-config.json") == .done)
        #expect(store.read("remote-config.json") == .missing)
    }

    @Test("a failed rename or sync leaves the old file valid and no tmp")
    func atomicReplacement() {
        _ = store.write("device.json", content: "old")
        test.fileSystem.failOnce(.rename)
        #expect(store.write("device.json", content: "new") == .failed(.io(code: -1, operation: "injected:rename")))
        #expect(content(store.read("device.json")) == "old")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("device.json.tmp").path))

        test.fileSystem.failOnce(.sync)
        #expect(store.write("device.json", content: "new") == .failed(.io(code: -1, operation: "injected:sync")))
        #expect(content(store.read("device.json")) == "old")
    }

    @Test("a crash between write and rename leaves a tmp that the next read deletes")
    func leftoverTmp() throws {
        _ = store.write("device.json", content: "old")
        try Data("half writ".utf8).write(to: root.appendingPathComponent("device.json.tmp"))
        #expect(content(store.read("device.json")) == "old")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("device.json.tmp").path))

        try Data("{}".utf8).write(to: root.appendingPathComponent("person.json.tmp"))
        #expect(store.read("person.json") == .missing)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("person.json.tmp").path))
    }

    @Test("an I/O error is unreadable and the file is left byte-identical; bad UTF-8 is unreadable")
    func unreadable() throws {
        _ = store.write("device.json", content: "keep me")
        let before = try Data(contentsOf: root.appendingPathComponent("device.json"))
        test.fileSystem.failOnce(.read)
        #expect(store.read("device.json") == .unreadable(.io(code: -1, operation: "injected:read")))
        #expect(try Data(contentsOf: root.appendingPathComponent("device.json")) == before)

        try Data([0x7B, 0xC3, 0x28, 0x7D]).write(to: root.appendingPathComponent("bad.json"))
        #expect(store.read("bad.json") == .unreadable(.io(code: EILSEQ, operation: "utf8")))
    }

    @Test("a failed write or delete reports failure instead of trapping")
    func failures() {
        test.fileSystem.failAlways(.openWrite)
        #expect(store.write("device.json", content: "x") == .failed(.io(code: -1, operation: "injected:openWrite")))
        test.fileSystem.heal()
        _ = store.write("device.json", content: "x")
        test.fileSystem.failAlways(.delete)
        #expect(store.delete("device.json") == .failed(.io(code: -1, operation: "injected:delete")))
    }

    @Test("a locked device is reported as locked on read, write and delete, and nothing is changed")
    func locked() throws {
        _ = store.write("device.json", content: "old")
        test.fileSystem.locked = true

        #expect(store.read("device.json") == .locked)
        #expect(store.write("device.json", content: "new") == .locked)
        #expect(store.delete("device.json") == .locked)

        test.fileSystem.locked = false
        #expect(content(store.read("device.json")) == "old")
    }

    @Test("the directory is excluded from backup by the first write")
    func backupExclusion() throws {
        let store = store
        _ = store.write("device.json", content: "{}")
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        #expect(test.fileSystem.calls.filter { $0 == .excludeFromBackup }.count == 1)
        _ = store.write("person.json", content: "{}")
        #expect(test.fileSystem.calls.filter { $0 == .excludeFromBackup }.count == 1)
    }

    @Test("files are app-private")
    func permissions() throws {
        _ = store.write("device.json", content: "{}")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: root.appendingPathComponent("device.json").path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }
}
