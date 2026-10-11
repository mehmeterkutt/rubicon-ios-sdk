import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `PrivacyTest`, over the writer; the Android test names are kept.
@Suite("Privacy")
struct PrivacyTests {
    /// A harness whose device file already holds `stored`, as a previous process would have left it.
    func harness(configure: (inout AnalyticsConfiguration) -> Void = { _ in }, stored: StoredConsent? = nil)
        -> WriterHarness
    {
        let root = TestPlatform.temporaryDirectory()
        if let stored {
            let test = TestPlatform(storageRoot: root)
            let store = DeviceStore(
                keyValueStore: FileKeyValueStore(root: root, fileSystem: test.fileSystem), log: test.log(level: .off),
                clock: test.clock, newDeviceId: { "device-0" })
            store.load()
            store.update { with($0) { $0.consent = stored } }
            store.persist()
        }
        return WriterHarness(configure: configure, storageRoot: root)
    }

    func storedConsent(_ h: WriterHarness) -> StoredConsent? {
        h.writer.requestPersist()
        h.runCurrent()
        return h.deviceStore.state?.consent
    }

    // MARK: the starting state

    @Test("GRANTED by default collects and is not opted out")
    func grantedByDefault() {
        let h = harness()
        h.writer.start()
        h.runCurrent()

        #expect(!h.consent.isOptedOut)
        #expect(h.consent.state == .granted)
    }

    @Test("PENDING is opted out, meaning nothing is sent now")
    func pendingIsOptedOut() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.runCurrent()

        #expect(h.consent.isOptedOut)
        #expect(h.consent.state == .pending)
    }

    @Test("a stored choice beats the default")
    func storedBeatsDefault() {
        let h = harness(configure: { $0.privacy.defaultConsent = .pending }, stored: .granted)
        h.writer.start()
        h.runCurrent()

        #expect(h.consent.state == .granted)
    }

    @Test("a stored opt-out survives a restart")
    func storedOptOut() {
        let h = harness(stored: .denied)
        h.writer.start()
        h.runCurrent()

        #expect(h.consent.state == .denied)
    }

    @Test("without persistConsent the stored value is neither read nor written")
    func withoutPersistConsent() {
        let h = harness(configure: { $0.privacy.persistConsent = false }, stored: .denied)
        h.writer.start()
        h.runCurrent()
        #expect(h.consent.state == .granted)

        h.consent.optIn()
        h.runCurrent()

        #expect(storedConsent(h) == .denied)
    }

    @Test("isOptedOut before the writer has loaded reads device.json once")
    func earlyIsOptedOut() {
        let h = harness(stored: .denied)
        #expect(h.consent.isOptedOut)
        h.writer.start()
        h.runCurrent()
        #expect(h.consent.isOptedOut)
    }

    @Test("calls before the stored choice is known apply in order once it is")
    func callsBeforeLoad() {
        let h = harness(stored: .denied)
        h.consent.optIn()
        h.consent.optOut()
        h.consent.optIn()
        h.writer.start()
        h.runCurrent()

        #expect(h.consent.state == .granted)
        #expect(storedConsent(h) == .granted)
    }

    // MARK: opting out

    @Test("startup events of an opted-out user never reach disk and are not counted")
    func startupEventsOptedOut() {
        let h = harness(stored: .denied)
        h.track("Early")
        h.writer.start()
        h.runCurrent()

        #expect(h.lines().isEmpty)
        #expect(h.deviceStore.state?.diagnostics.dropped == [:])
    }

    @Test("nothing new is created, and events queued before still go")
    func nothingNew() {
        let h = harness()
        h.writer.start()
        h.track("Before")
        h.runCurrent()

        h.consent.optOut()
        h.track("After")
        h.writer.flush()
        h.runCurrent()

        #expect(h.names() == ["Before"])
        #expect(h.signals() == 1)
        #expect(storedConsent(h) == .denied)
    }

    @Test("the open session ends without Session Ended, and no session events follow")
    func sessionEndsSilently() {
        let h = harness { $0.autocapture.enabled = [.sessions] }
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.track("Opened")
        h.runCurrent()

        h.consent.optOut()
        h.test.lifecycleSource.moveToBackground()
        h.pass(3_600_000)
        h.test.lifecycleSource.moveToForeground()
        h.track("Ignored")
        h.runCurrent()

        #expect(h.names() == ["Session Started", "Opened"])
        #expect(h.personStore.state?.session == nil)
    }

    @Test("identify, register and reset still update local state, without events")
    func localStateWhileOptedOut() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        h.consent.optOut()

        let ticket = h.identity.identify("user-42", traits: ["plan": "pro"])
        h.identity.register("theme", value: "dark")

        #expect(ticket?.decision == .noEvent)
        #expect(h.personStore.state?.userId == "user-42")
        #expect(h.personStore.state?.superProperties == ["theme": .string("dark")])
    }

    @Test("opting in produces no event and the next event starts a new session")
    func optInNewSession() {
        let h = harness { $0.autocapture.enabled = [.sessions] }
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()
        h.consent.optOut()
        h.consent.optIn()
        h.track("Back")
        h.runCurrent()

        #expect(h.names() == ["Session Started", "Back"])
        #expect(h.logged(.info, containing: "opted in"))
    }

    // MARK: pending consent

    @Test("events are written but the uploader gate stays closed")
    func pendingWritten() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.track("Waiting")
        h.runCurrent()

        #expect(h.names() == ["Waiting"])
        #expect(h.consent.state == .pending)
        #expect(!h.consent.allowsUploads)
    }

    @Test("only pending closes the upload gate")
    func onlyPendingCloses() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.runCurrent()
        #expect(!h.consent.allowsUploads)

        h.consent.optIn()
        #expect(h.consent.allowsUploads)
        h.consent.optOut()
        #expect(h.consent.allowsUploads)
    }

    @Test("optIn uploads the waiting events")
    func optInUploads() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.track("Waiting")
        h.runCurrent()

        h.consent.optIn()
        h.runCurrent()

        #expect(h.signals() == 1)
        #expect(h.eventStore.closedSegments().count == 1)
    }

    @Test("optOut deletes the waiting events without counting them")
    func optOutDeletes() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        for _ in 0..<3 { h.track("Waiting") }
        h.runCurrent()

        h.consent.optOut()
        h.runCurrent()

        #expect(h.lines().isEmpty)
        #expect(h.eventStore.pendingCount == 0)
        #expect(h.deviceStore.state?.diagnostics.dropped == [:])
        #expect(h.dropped.isEmpty)
    }

    @Test("with no stored decision, pending continues after a restart")
    func pendingContinues() {
        let h = harness { $0.privacy.defaultConsent = .pending }
        h.writer.start()
        h.runCurrent()

        #expect(h.deviceStore.state?.consent == nil)
        #expect(h.consent.state == .pending)
    }

    // MARK: clearing local data

    @Test("deletes events and the person, renews the device id, keeps consent, version and remote config")
    func clearLocalData() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        _ = h.identity.identify("user-42", traits: [:])
        h.identity.register("plan", value: "pro")
        h.consent.optIn()
        h.deviceStore.update {
            with($0) {
                $0.lastVersion = "1.4.0"
                $0.lastBuild = "140"
            }
        }
        h.deviceStore.updateRemoteConfig(RemoteConfigCache(etag: "\"e\"", values: ["flush_at": .int(50)]))
        h.deviceStore.countDropped(.expired, count: 2)
        for _ in 0..<3 { h.track("Before") }
        h.runCurrent()
        let oldDeviceId = h.identity.deviceId

        h.identity.clearLocalData(newDeviceId: h.ids.next())
        h.writer.clearLocalData()
        h.track("After")
        h.runCurrent()

        let device = h.deviceStore.state
        #expect(h.names() == ["After"])
        #expect(device?.deviceId != oldDeviceId)
        #expect(h.field(h.lines()[0], "device_id") == device?.deviceId)
        #expect(h.field(h.lines()[0], "user_id") == nil)
        #expect(h.personStore.state?.userId == nil)
        #expect(h.personStore.state?.superProperties == [:])
        #expect(device?.consent == .granted)
        #expect(device?.lastVersion == "1.4.0")
        #expect(device?.lastBuild == "140")
        #expect(h.deviceStore.remoteConfig == RemoteConfigCache(etag: "\"e\"", values: ["flush_at": .int(50)]))
        #expect(device?.diagnostics.dropped == [:])
    }

    @Test("produces no Session Ended and counts nothing")
    func noSessionEnded() {
        let h = harness()
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.track("Opened")
        h.runCurrent()

        h.identity.clearLocalData(newDeviceId: h.ids.next())
        h.writer.clearLocalData()
        h.runCurrent()

        #expect(h.lines().isEmpty)
        #expect(h.dropped.isEmpty)
        #expect(h.deviceStore.state?.diagnostics.dropped == [:])
    }

    @Test("the files are written by the writer")
    func filesWritten() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        let before = h.identity.deviceId

        h.identity.clearLocalData(newDeviceId: h.ids.next())
        h.runCurrent()

        guard case .present(let stored) = h.keyValueStore.read(DeviceStore.fileName) else {
            Issue.record("device.json missing")
            return
        }
        #expect(!stored.contains(before))
        #expect(stored.contains(h.deviceStore.state?.deviceId ?? "?"))
    }
}
