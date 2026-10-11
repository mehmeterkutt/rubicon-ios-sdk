import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The controller on its own; the Android `PrivacyTest` runs over the writer and is ported with it
/// (step 6.3b, `PrivacyTests`).
@Suite("ConsentController")
struct ConsentControllerTests {
    let support = StoreTestSupport()
    let changes = Locked<[(ConsentState, ConsentState)]>([])

    func deviceStore() -> DeviceStore {
        DeviceStore(
            keyValueStore: support.files, log: support.log, clock: TestClock(), newDeviceId: support.newDeviceId)
    }

    func store(_ consent: StoredConsent) {
        let store = deviceStore()
        store.load()
        store.update { with($0) { $0.consent = consent } }
        store.persist()
    }

    func controller(
        defaultConsent: Consent = .granted, persistConsent: Bool = true, store: DeviceStore? = nil
    ) -> (ConsentController, DeviceStore) {
        let device = store ?? deviceStore()
        let controller = ConsentController(
            defaultConsent: defaultConsent, persistConsent: persistConsent, deviceStore: device, log: support.log,
            onChange: { [changes] from, to in changes.withLock { $0.append((from, to)) } })
        return (controller, device)
    }

    func loaded(_ pair: (ConsentController, DeviceStore)) -> ConsentController {
        pair.1.load()
        pair.0.load()
        return pair.0
    }

    var transitions: [String] { changes.current.map { "\($0.0)->\($0.1)" } }

    @Test("GRANTED by default collects and is not opted out")
    func grantedByDefault() {
        let consent = loaded(controller())
        #expect(!consent.isOptedOut)
        #expect(consent.state == .granted)
        #expect(consent.allowsUploads)
    }

    @Test("PENDING is opted out, meaning nothing is sent now")
    func pendingIsOptedOut() {
        let consent = loaded(controller(defaultConsent: .pending))
        #expect(consent.isOptedOut)
        #expect(consent.state == .pending)
        #expect(!consent.allowsUploads)
    }

    @Test("a stored choice beats the default")
    func storedBeatsDefault() {
        store(.granted)
        #expect(loaded(controller(defaultConsent: .pending)).state == .granted)
    }

    @Test("a stored opt-out survives a restart")
    func storedOptOut() {
        store(.denied)
        let consent = loaded(controller())
        #expect(consent.state == .denied)
        #expect(consent.isOptedOut)
        #expect(consent.allowsUploads)
    }

    @Test("without persistConsent the stored value is neither read nor written")
    func withoutPersistConsent() {
        store(.denied)
        let (controller, device) = controller(persistConsent: false)
        device.load()
        controller.load()
        #expect(controller.state == .granted)

        controller.optOut()
        controller.optIn()
        device.persist()

        #expect(device.state?.consent == .denied)
        #expect(transitions == ["granted->denied", "denied->granted"])
    }

    @Test("isOptedOut before the writer has loaded reads device.json once")
    func earlyIsOptedOut() {
        store(.denied)
        let (controller, device) = controller()

        #expect(controller.isOptedOut)
        #expect(device.isLoaded)
        device.load()
        controller.load()
        #expect(controller.isOptedOut)
        #expect(controller.state == .denied)
    }

    @Test("calls before the stored choice is known apply in order once it is")
    func callsBeforeLoad() {
        store(.denied)
        let (controller, device) = controller()
        controller.optIn()
        controller.optOut()
        controller.optIn()
        #expect(transitions.isEmpty)

        device.load()
        controller.load()

        #expect(controller.state == .granted)
        device.persist()
        #expect(device.state?.consent == .granted)
        #expect(transitions == ["denied->granted", "granted->denied", "denied->granted"])
    }

    @Test("only pending closes the upload gate")
    func uploadGate() {
        let consent = loaded(controller(defaultConsent: .pending))
        #expect(!consent.allowsUploads)

        consent.optIn()
        #expect(consent.allowsUploads)
        consent.optOut()
        #expect(consent.allowsUploads)
    }

    @Test("a change is logged at INFO and the same state twice tells the writer once")
    func loggedOnce() {
        let consent = loaded(controller())
        consent.optOut()
        consent.optOut()
        consent.optIn()

        #expect(transitions == ["granted->denied", "denied->granted"])
        let info = support.test.logger.lines.filter { $0.level == .info }.map(\.message)
        #expect(info == ["The user opted out; nothing new is collected", "The user opted in; collection resumes"])
    }

    @Test("before the first unlock isOptedOut answers from defaultConsent and the calls wait for the writer")
    func lockedDevice() throws {
        store(.denied)
        support.test.fileSystem.locked = true
        let (controller, device) = controller(defaultConsent: .granted)

        #expect(!controller.isOptedOut)
        #expect(!device.isLoaded)
        controller.optIn()
        #expect(transitions.isEmpty)
        let (pendingController, _) = self.controller(defaultConsent: .pending)
        #expect(pendingController.isOptedOut)

        support.test.fileSystem.locked = false
        device.load()
        controller.load()

        #expect(controller.state == .granted)
        #expect(transitions == ["denied->granted"])
    }
}
