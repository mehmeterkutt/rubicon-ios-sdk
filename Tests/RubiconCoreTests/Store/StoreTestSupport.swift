import Foundation
import RubiconTesting

@testable import RubiconCore

/// A file store over a fresh directory and a fake file system, a log and helpers shared by the
/// store tests.
final class StoreTestSupport: @unchecked Sendable {
    let test = TestPlatform()
    let counted = Locked<[Code]>([])
    lazy var log = Log(
        level: .debug, logger: nil, platformLogger: test.logger.asLogger,
        issues: { [counted] code in counted.withLock { $0.append(code) } })
    lazy var files = FileKeyValueStore(root: test.storageRoot, fileSystem: test.fileSystem)
    private let ids = Locked(0)

    /// Device ids `device-1`, `device-2` and so on.
    var newDeviceId: @Sendable () -> String {
        { [ids] in
            ids.withLock {
                $0 += 1
                return "device-\($0)"
            }
        }
    }

    /// The stored file parsed by the independent parser.
    func stored(_ name: String) throws -> [String: JSONValue] {
        guard case .present(let content) = files.read(name), case .object(let object) = try JSONValue.parse(content)
        else {
            throw NSError(
                domain: "StoreTestSupport", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(name) is not present"])
        }
        return object
    }

    func writeRaw(_ name: String, _ content: String) throws {
        try writeRaw(name, Data(content.utf8))
    }

    func writeRaw(_ name: String, _ bytes: Data) throws {
        try FileManager.default.createDirectory(at: test.storageRoot, withIntermediateDirectories: true)
        try bytes.write(to: test.storageRoot.appendingPathComponent(name))
    }

    func rawBytes(_ name: String) throws -> Data {
        try Data(contentsOf: test.storageRoot.appendingPathComponent(name))
    }

    /// How many files the store wrote so far: one rename per successful write.
    var writeCount: Int { test.fileSystem.calls.filter { $0 == .rename }.count }

    func warned(_ code: Code) -> Bool {
        test.logger.lines.contains { $0.level == .warn && $0.message.contains(code.rawValue) }
    }
    func errored(_ code: Code) -> Bool {
        test.logger.lines.contains { $0.level == .error && $0.message.contains(code.rawValue) }
    }
}
