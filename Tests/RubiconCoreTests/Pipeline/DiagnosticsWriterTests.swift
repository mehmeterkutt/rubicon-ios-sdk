import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The `in the writer` half of the Android `DiagnosticsTest`; the Android test names are kept.
@Suite("Diagnostics in the writer")
struct DiagnosticsWriterTests {
    let hour = Diagnostics.intervalMs

    func diagnosticsLines(_ h: WriterHarness) -> [String] {
        h.lines().filter { h.field($0, "event") == Diagnostics.eventName }
    }

    @Test("a silent device sends nothing")
    func silentDevice() {
        let h = WriterHarness()
        h.writer.start()
        h.track()
        h.writer.flush()
        h.runCurrent()

        #expect(diagnosticsLines(h).isEmpty)
    }

    @Test("comes right before a flush and resets the counters once written")
    func beforeFlush() {
        let h = WriterHarness()
        h.writer.start()
        h.runCurrent()
        h.deviceStore.countDropped(.expired, count: 2)
        h.log.warn(.hostBlocked) { "blocked" }
        h.track("Before")
        h.writer.flush()
        h.runCurrent()

        #expect(h.names() == ["Before", Diagnostics.eventName])
        #expect(h.eventStore.segmentLines(0).count == 2)
        let diagnostics = h.deviceStore.state?.diagnostics
        #expect(diagnostics?.dropped == [:])
        #expect(diagnostics?.issues == [:])
        #expect(diagnostics?.periodStart == nil)
        #expect(diagnostics?.lastSentAt == h.test.clock.now())
    }

    @Test("at most once an hour, also across restarts")
    func onceAnHour() {
        let root = TestPlatform.temporaryDirectory()
        let first = WriterHarness(storageRoot: root)
        first.writer.start()
        first.runCurrent()
        first.deviceStore.countDropped(.expired)
        first.writer.flush()
        first.runCurrent()
        first.deviceStore.countDropped(.expired)
        first.writer.flush()
        first.runCurrent()

        #expect(diagnosticsLines(first).count == 1)
        first.writer.requestPersist()
        first.runCurrent()

        let second = WriterHarness(storageRoot: root)
        second.writer.start()
        second.writer.flush()
        second.runCurrent()
        #expect(diagnosticsLines(second).isEmpty)

        second.test.clock.advance(byMillis: hour)
        second.writer.flush()
        second.runCurrent()
        #expect(diagnosticsLines(second).count == 1)
    }

    @Test("counters stay when the event could not be written")
    func countersStay() {
        let h = WriterHarness()
        h.writer.start()
        h.runCurrent()
        h.deviceStore.countDropped(.expired, count: 2)
        h.eventStore.failAppends = true
        h.writer.flush()
        h.runCurrent()

        #expect(h.deviceStore.state?.diagnostics.dropped["expired"] == 2)
        #expect(h.deviceStore.state?.diagnostics.lastSentAt == nil)
    }

    @Test("opted out keeps counting and reports after optIn")
    func optedOut() {
        let h = WriterHarness()
        h.writer.start()
        h.runCurrent()
        h.consent.optOut()
        h.deviceStore.countDropped(.expired)
        h.writer.flush()
        h.runCurrent()
        #expect(diagnosticsLines(h).isEmpty)
        #expect(h.deviceStore.state?.diagnostics.dropped["expired"] == 1)

        h.consent.optIn()
        h.writer.flush()
        h.runCurrent()

        #expect(diagnosticsLines(h).count == 1)
    }

    @Test("never while consent is pending")
    func neverPending() {
        let h = WriterHarness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.runCurrent()
        h.deviceStore.countDropped(.expired)
        h.writer.flush()
        h.runCurrent()

        #expect(diagnosticsLines(h).isEmpty)
    }

    @Test("never when switched off in code or by a remote rate of zero")
    func switchedOff() {
        let inCode = WriterHarness { $0.logging.sendDiagnostics = false }
        inCode.writer.start()
        inCode.runCurrent()
        inCode.deviceStore.countDropped(.expired)
        inCode.writer.flush()
        inCode.runCurrent()
        #expect(diagnosticsLines(inCode).isEmpty)

        let remote = WriterHarness()
        remote.deviceStore.load()
        remote.deviceStore.updateRemoteConfig(
            RemoteConfigCache(etag: nil, values: ["diagnostics_sample_rate": .int(0)]))
        remote.deviceStore.persist()
        remote.writer.start()
        remote.runCurrent()
        remote.deviceStore.countDropped(.expired)
        remote.writer.flush()
        remote.runCurrent()
        #expect(diagnosticsLines(remote).isEmpty)
    }
}
