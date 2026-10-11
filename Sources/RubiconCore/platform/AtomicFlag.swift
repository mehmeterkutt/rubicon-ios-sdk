import Foundation

/// A once-only switch shared between threads (the conflated upload signal, the callback guard's
/// switches, the `F_FULLFSYNC` fallback). `set()` returns `true` for the one caller that flipped it.
package final class AtomicFlag: @unchecked Sendable {
    // Guarded by `lock`.
    private var value = false
    private let lock = NSLock()

    package init() {}

    package var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Sets the flag; `true` when it was clear before.
    @discardableResult
    package func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = value
        value = true
        return !was
    }

    /// Clears the flag; `true` when it was set before.
    @discardableResult
    package func clear() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let was = value
        value = false
        return was
    }
}

/// A value guarded by a lock, for the small shared state the workers and listeners exchange.
package final class Locked<Value>: @unchecked Sendable {
    // Guarded by `lock`.
    private var value: Value
    private let lock = NSLock()

    package init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    package func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    package var current: Value {
        withLock { $0 }
    }
}
