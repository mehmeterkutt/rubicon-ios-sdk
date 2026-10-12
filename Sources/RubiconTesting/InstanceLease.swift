import Foundation

/// One test at a time may own the process-wide instance (Configuration 3): the fixture of every
/// suite that creates it, in every test target, holds a lease for its lifetime, taken before its
/// `resetForTests` and released after. Swift Testing runs suites in parallel and `swift test` runs
/// the core and the Rubicon test targets in one process, so a `.serialized` parent in each module is
/// not enough: in CI a fixture of one target reset the instance a test of the other had just
/// created, which left its writer stopped with the messages uncounted (plan section 15, 2026-10-12).
/// One fixture per test: a second lease in the same test would wait for the first forever.
package final class InstanceLease: @unchecked Sendable {
    // A semaphore, not a lock: a fixture may be released on another thread than the one that made it.
    private static let free = DispatchSemaphore(value: 1)

    /// Waits until no other fixture holds the instance.
    package init() {
        Self.free.wait()
    }

    deinit {
        Self.free.signal()
    }
}
