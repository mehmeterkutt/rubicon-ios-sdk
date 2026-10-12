import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("InstanceLease")
struct InstanceLeaseTests {
    @Test("a second lease waits until the first is released, on any thread")
    func secondWaits() {
        var first: InstanceLease? = InstanceLease()
        let taken = DispatchSemaphore(value: 0)
        let secondTaken = Locked(false)
        let waiter = Thread {
            let second = InstanceLease()
            secondTaken.withLock { $0 = true }
            taken.signal()
            withExtendedLifetime(second) {}
        }
        waiter.start()

        Thread.sleep(forTimeInterval: 0.2)
        #expect(!secondTaken.current)
        first = nil
        #expect(taken.wait(timeout: .now() + 5) == .success)
        #expect(secondTaken.current)
    }
}
