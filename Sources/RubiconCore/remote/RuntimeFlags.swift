import Foundation

/// The two remote switches that apply at once, outside the snapshot (Configuration 1, rule 3): the
/// kill switch and network request capture. They only ever turn off within a process; turning back
/// on waits for the next launch, like every other remote value.
///
/// The pipeline checks `isCollecting` before it creates or uploads an event (6.3, 6.4), and the
/// network observer checks `isCapturingNetworkRequests` on every call (7.6). Read from any thread.
package final class RuntimeFlags: Sendable {
    private let collecting: AtomicFlag
    private let capturing: AtomicFlag

    package init(collecting: Bool = true, capturingNetworkRequests: Bool = true) {
        self.collecting = AtomicFlag()
        self.capturing = AtomicFlag()
        if !collecting { self.collecting.set() }
        if !capturingNetworkRequests { capturing.set() }
    }

    /// `false` after the kill switch, or on a device outside `sample_rate`.
    package var isCollecting: Bool { !collecting.isSet }
    package var isCapturingNetworkRequests: Bool { !capturing.isSet }

    package func stopCollecting() {
        collecting.set()
    }

    package func stopCapturingNetworkRequests() {
        capturing.set()
    }
}
