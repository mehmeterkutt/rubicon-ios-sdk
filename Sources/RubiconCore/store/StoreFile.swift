import Foundation

/// Turns a store's value into the fields of its file and back; the version field is the
/// `StoreFile`'s.
package protocol StoreCodec: Sendable {
    associatedtype Value: Sendable & Equatable
    func encode(_ value: Value) -> [String: PropertyValue]
    /// The value of `fields`, or `nil` when a field is missing or has the wrong type.
    func decode(_ fields: JsonFields) -> Value?
}

/// One store file with memory as the source of truth (Disk 7, Identity 1, iOS Disk 1).
///
/// - `load` reads the file once, on the writer. Missing: `onMissing`, written at once if asked.
///   Unreadable, corrupt or of a newer version: `onUnreadable` in memory, one WARN, and the file is
///   never written for the rest of the process. Locked: nothing is loaded; `load` is called again
///   once protected data is available.
/// - `update` changes the value in memory at once, from any thread.
/// - `persist`, on the writer only, writes the latest value if it changed since the last write, so
///   any number of updates in between cost one write. A failed write logs an ERROR and is retried
///   by the next `persist`; a locked write is kept quietly for the same retry.
package final class StoreFile<Codec: StoreCodec>: @unchecked Sendable {
    package typealias Value = Codec.Value

    package static var versionKey: String { "v" }
    /// The format version this SDK writes and reads; a file with another one is unreadable (Disk 7).
    package static var version: Int64 { 1 }

    private struct State {
        var current: Value?
        var dirty = false
        var loaded = false
        var writable = true
        var locked = false
    }

    private let name: String
    private let keyValueStore: any KeyValueStore
    private let log: Log
    private let codec: Codec
    // Guarded by `state`.
    private let state = Locked(State())

    package init(name: String, keyValueStore: any KeyValueStore, log: Log, codec: Codec) {
        self.name = name
        self.keyValueStore = keyValueStore
        self.log = log
        self.codec = codec
    }

    package var isLoaded: Bool { state.current.loaded }

    /// `false` when the file exists but could not be used; it is then never written (Identity 1).
    package var isWritable: Bool { state.current.writable }

    /// `true` after a read or write met the locked device; cleared by the next successful one.
    package var isLocked: Bool { state.current.locked }

    package var value: Value? { state.current.current }

    /// With `writeMissing` `false` a missing file's value stays unwritten until the next `persist`.
    /// Returns `false` when the device is locked and nothing could be loaded.
    @discardableResult
    package func load(onMissing: () -> Value?, onUnreadable: () -> Value?, writeMissing: Bool = true) -> Bool {
        let loaded: Value?
        switch keyValueStore.read(name) {
        case .missing:
            state.withLock { $0.dirty = true }
            loaded = onMissing()
        case .unreadable(let cause):
            loaded = unreadable(cause, onUnreadable)
        case .locked:
            state.withLock { $0.locked = true }
            log.debug { "\(name) cannot be read while the device is locked; waiting for protected data" }
            return false
        case .present(let content):
            loaded = decode(content) ?? unreadable(nil, onUnreadable)
        }
        state.withLock { s in
            s.current = loaded
            s.loaded = true
            s.locked = false
            if loaded == nil { s.dirty = false }
        }
        if loaded != nil && writeMissing { persist() }
        return true
    }

    package func update(_ transform: (Value?) -> Value?) {
        state.withLock { s in
            let next = transform(s.current)
            if next != s.current {
                s.current = next
                s.dirty = true
            }
        }
    }

    /// Returns `false` when a change could not be written because of an I/O failure.
    @discardableResult
    package func persist() -> Bool {
        let snapshot: (write: Bool, value: Value?) = state.withLock { s in
            guard s.writable, s.dirty else { return (false, nil) }
            s.dirty = false
            return (true, s.current)
        }
        guard snapshot.write else { return true }
        let outcome: KeyValueWrite
        if let value = snapshot.value {
            var fields = codec.encode(value)
            fields[Self.versionKey] = .int(Self.version)
            do {
                outcome = keyValueStore.write(name, content: try Json.write(fields))
            } catch {
                // The codecs produce finite numbers only; this is a bug, reported, not a crash.
                outcome = .failed(.io(code: -1, operation: "encode"))
            }
        } else {
            outcome = keyValueStore.delete(name)
        }
        switch outcome {
        case .done:
            state.withLock { $0.locked = false }
            return true
        case .locked:
            state.withLock { s in
                s.dirty = true
                s.locked = true
            }
            log.debug { "\(name) cannot be written while the device is locked; the change is kept in memory" }
            return true
        case .failed(let error):
            state.withLock { $0.dirty = true }
            log.error(.storageWriteFailed, error) {
                "Could not write \(name); the change is kept in memory and written later"
            }
            return false
        }
    }

    private func decode(_ content: String) -> Value? {
        guard let fields = Json.readObject(content), fields.int64(Self.versionKey) == Self.version else { return nil }
        return codec.decode(fields)
    }

    private func unreadable(_ cause: FileSystemError?, _ fallback: () -> Value?) -> Value? {
        state.withLock { $0.writable = false }
        log.warn(.storeUnreadable, cause) {
            "\(name) exists but cannot be read; using values in memory for this process and leaving the file untouched"
        }
        return fallback()
    }
}

/// Strict reading for store codecs: a field that is missing or JSON `null` is absent, a field of
/// the wrong type makes the whole file corrupt (Android log 4.1).
package struct StoreFields {
    package struct Corrupt: Error {}

    package let fields: JsonFields

    package init(_ fields: JsonFields) {
        self.fields = fields
    }

    private func absent(_ key: String) -> Bool { !fields.has(key) || fields.isNull(key) }

    package func optionalString(_ key: String) throws(Corrupt) -> String? {
        if absent(key) { return nil }
        guard let value = fields.string(key) else { throw Corrupt() }
        return value
    }

    package func requiredString(_ key: String) throws(Corrupt) -> String {
        guard let value = try optionalString(key) else { throw Corrupt() }
        return value
    }

    package func optionalInt64(_ key: String) throws(Corrupt) -> Int64? {
        if absent(key) { return nil }
        guard let value = fields.int64(key) else { throw Corrupt() }
        return value
    }

    package func requiredInt64(_ key: String) throws(Corrupt) -> Int64 {
        guard let value = try optionalInt64(key) else { throw Corrupt() }
        return value
    }

    package func optionalInt(_ key: String) throws(Corrupt) -> Int? {
        if absent(key) { return nil }
        guard let value = fields.int(key) else { throw Corrupt() }
        return value
    }

    package func optionalDate(_ key: String) throws(Corrupt) -> Date? {
        try optionalInt64(key).map(Date.init(epochMillis:))
    }

    package func requiredDate(_ key: String) throws(Corrupt) -> Date {
        Date(epochMillis: try requiredInt64(key))
    }

    package func optionalFields(_ key: String) throws(Corrupt) -> StoreFields? {
        if absent(key) { return nil }
        guard let nested = fields.fields(key) else { throw Corrupt() }
        return StoreFields(nested)
    }

    package func optionalObject(_ key: String) throws(Corrupt) -> [String: PropertyValue]? {
        if absent(key) { return nil }
        guard let object = fields.object(key) else { throw Corrupt() }
        return object
    }

    /// An object of whole numbers, such as counters; empty when absent.
    package func intMap(_ key: String) throws(Corrupt) -> [String: Int] {
        guard let nested = try optionalFields(key) else { return [:] }
        var out: [String: Int] = [:]
        for name in nested.fields.keys {
            guard let value = nested.fields.int(name) else { throw Corrupt() }
            out[name] = value
        }
        return out
    }
}

extension [String: Int] {
    /// A `PropertyValue` object of counters.
    package var propertyValue: PropertyValue {
        .object(mapValues { .int(Int64($0)) })
    }
}
