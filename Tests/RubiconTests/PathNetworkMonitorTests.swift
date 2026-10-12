import Foundation
import Network
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore

/// The network monitor of iOS Retry 1 and iOS Context 2 (step 7.2).
@Suite("PathNetworkMonitor")
struct PathNetworkMonitorTests {
    typealias Reading = PathNetworkMonitor.Reading

    @Test("satisfied and requiresConnection are connected, unsatisfied is not")
    func statusMapping() {
        #expect(Reading.of(status: .satisfied, interfaces: [.wifi]).connected)
        #expect(Reading.of(status: .requiresConnection, interfaces: [.cellular]).connected)
        #expect(!Reading.of(status: .unsatisfied, interfaces: [.wifi]).connected)
    }

    @Test("the network type follows the first interface in the decided order, and is nil offline")
    func typeMapping() {
        #expect(Reading.of(status: .satisfied, interfaces: [.wifi, .cellular]).networkType == "wifi")
        #expect(Reading.of(status: .satisfied, interfaces: [.cellular]).networkType == "cellular")
        #expect(Reading.of(status: .satisfied, interfaces: [.wiredEthernet]).networkType == "ethernet")
        #expect(Reading.of(status: .satisfied, interfaces: [.loopback, .other]).networkType == nil)
        #expect(Reading.of(status: .unsatisfied, interfaces: [.wifi]).networkType == nil)
    }

    @Test("optimistic before the first path; listeners hear connectivity changes once each, not type changes")
    func listeners() {
        let monitor = PathNetworkMonitor()
        let changes = Locked<[Bool]>([])
        let token = monitor.addListener { connected in changes.withLock { $0.append(connected) } }
        #expect(monitor.isConnected)
        #expect(monitor.networkType == nil)
        #expect(!monitor.hasPath)

        monitor.apply(Reading(connected: true, networkType: "wifi"))
        monitor.apply(Reading(connected: true, networkType: "cellular"))
        monitor.apply(Reading(connected: false, networkType: nil))
        monitor.apply(Reading(connected: false, networkType: nil))
        monitor.apply(Reading(connected: true, networkType: "wifi"))

        #expect(changes.current == [false, true])
        #expect(monitor.isConnected)
        #expect(monitor.networkType == "wifi")
        token.cancel()
        monitor.apply(Reading(connected: false, networkType: nil))
        #expect(changes.current == [false, true])
    }

    @Test("the real monitor starts once and delivers a path")
    func realMonitor() async {
        let monitor = PathNetworkMonitor()
        monitor.start()
        monitor.start()

        let deadline = Date().addingTimeInterval(5)
        while !monitor.hasPath && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(monitor.hasPath)
    }
}
