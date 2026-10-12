import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

/// The port of the Android `WriterTest`; the Android test names are kept.
@Suite("Writer")
struct WriterTests {
    func harness(configure: (inout AnalyticsConfiguration) -> Void = { _ in }) -> WriterHarness {
        WriterHarness(configure: configure)
    }

    // MARK: order and startup

    @Test("events from one thread are stored in call order")
    func callOrder() {
        let h = harness { $0.flush.at = 100 }
        h.writer.start()
        for i in 0..<50 { h.track("E\(i)") }
        h.runCurrent()

        #expect(h.names() == (0..<50).map { "E\($0)" })
    }

    @Test("calls made before the writer started keep their order and identity")
    func beforeStart() {
        let h = harness()
        _ = h.identity.identify("user-42", traits: [:])
        h.track()
        h.writer.start()
        h.runCurrent()

        #expect(h.lines().count == 1)
        #expect(h.field(h.lines()[0], "user_id") == "user-42")
    }

    @Test("the stores are loaded and written by the writer")
    func storesWritten() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        h.identity.register("plan", value: "pro")
        h.runCurrent()

        guard case .present = h.keyValueStore.read(DeviceStore.fileName) else {
            Issue.record("device.json missing")
            return
        }
        guard case .present(let person) = h.keyValueStore.read(PersonStore.fileName) else {
            Issue.record("person.json missing")
            return
        }
        #expect(person.contains("\"plan\""))
    }

    @Test("nothing is flushed at startup")
    func noStartupFlush() {
        let h = harness()
        h.writer.start()
        h.runCurrent()

        #expect(h.signals() == 0)
    }

    // MARK: context cache

    @Test("is refreshed after the network monitor starts, before the first event and before each message")
    func contextRefresh() {
        let h = harness()
        h.writer.start()
        h.runCurrent()

        #expect(h.test.networkMonitor.starts == 1)
        #expect(h.test.contextProvider.refreshes == 1)

        h.track()
        h.track()
        h.runCurrent()

        #expect(h.test.contextProvider.refreshes == 3)
    }

    @Test("an event captured before the cache was ready gets the values when it is written")
    func pendingCache() {
        let h = harness()
        let provider = FakeContextProvider(
            staticValues: .none, callTimeValues: CallTimeValues(locale: "tr-TR", timezone: "Europe/Istanbul"),
            pendingUntilRefresh: true)
        // The harness's provider is the platform's; build the captured values from a pending one.
        let captured = provider.callTimeValues(disabled: [])
        #expect(captured.pending)
        h.test.contextProvider.callTimeValues = CallTimeValues(locale: "tr-TR", timezone: "Europe/Istanbul")

        h.track(callTime: captured)
        h.writer.start()
        h.runCurrent()

        guard case .object(let object)? = try? JSONValue.parse(h.lines().last ?? ""),
            case .object(let context)? = object["context"]
        else {
            Issue.record("no context")
            return
        }
        #expect(context["locale"] == .string("tr-TR"))
        #expect(context["timezone"] == .string("Europe/Istanbul"))
    }

    @Test("values captured from a ready cache are kept, not replaced at write time")
    func readyCacheKept() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        h.test.contextProvider.callTimeValues = CallTimeValues(locale: "de-DE")

        h.track(callTime: CallTimeValues(locale: "tr-TR"))
        h.runCurrent()

        guard case .object(let object)? = try? JSONValue.parse(h.lines().last ?? ""),
            case .object(let context)? = object["context"]
        else {
            Issue.record("no context")
            return
        }
        #expect(context["locale"] == .string("tr-TR"))
    }

    // MARK: the observer and drops

    @Test("sees Queued for exactly the stored events")
    func queuedForStored() {
        let h = harness()
        h.writer.start()
        h.track("A")
        h.runCurrent()
        h.eventStore.failAppends = true
        h.track("B")
        h.runCurrent()

        #expect(h.queued == ["m-1"])
    }

    @Test("a pipeline drop is counted and reported")
    func pipelineDrop() {
        let h = harness { $0.beforeSend = [{ _ in nil }] }
        h.writer.start()
        h.track()
        h.runCurrent()

        #expect(h.dropped.count == 1)
        #expect(h.dropped.first?.reason == .beforeSend)
        #expect(h.deviceStore.state?.diagnostics.dropped == ["before_send": 1])
        #expect(h.lines().isEmpty)
    }

    @Test("a full channel drops as backpressure without blocking")
    func backpressure() {
        let h = harness()
        // Not started: nothing drains the channel.
        let accepted = (1...1001).map { _ in h.track() }

        #expect(accepted.filter { $0 }.count == 1000)
        #expect(accepted.last == false)
        #expect(h.dropped.count == 1)
        #expect(h.dropped.first?.reason == .backpressure)
        h.writer.start()
        h.runCurrent()
        // The count reaches SDK Diagnostics at the first flush (Logging 5).
        let report = h.lines().first { h.field($0, "event") == Diagnostics.eventName }
        #expect(report?.contains("\"backpressure\":1") == true)
    }

    @Test("nothing is created once collecting is off")
    func collectingOff() {
        let h = harness()
        h.writer.start()
        h.track("Before")
        h.runCurrent()
        h.flags.stopCollecting()
        h.track("After")
        h.runCurrent()

        #expect(h.names() == ["Before"])
    }

    @Test("a remote kill switch saved earlier stops collection from the start")
    func killSwitch() {
        let h = harness()
        h.deviceStore.load()
        h.deviceStore.updateRemoteConfig(RemoteConfigCache(etag: nil, values: ["enabled": .bool(false)]))
        h.deviceStore.persist()
        h.writer.start()
        h.track()
        h.runCurrent()

        #expect(h.lines().isEmpty)
    }

    // MARK: flush triggers

    @Test("the count fires once at flush_at events")
    func countTrigger() {
        let h = harness()
        h.writer.start()
        for _ in 0..<4 { h.track() }
        h.runCurrent()
        #expect(h.signals() == 0)

        h.track()
        h.runCurrent()
        #expect(h.signals() == 1)
        #expect(h.eventStore.closedSegments().count == 1)

        for _ in 0..<4 { h.track() }
        h.runCurrent()
        #expect(h.signals() == 0)
    }

    @Test("events left by a previous process count, once")
    func leftoverCount() {
        let h = harness()
        for i in 0..<7 { _ = h.eventStore.append(#"{"type":"track","message_id":"old\#(i)","timestamp":1}"#) }
        h.writer.start()
        h.runCurrent()
        #expect(h.signals() == 0)

        h.track()
        h.runCurrent()
        #expect(h.signals() == 1)
        h.track()
        h.runCurrent()
        #expect(h.signals() == 0)
    }

    @Test("the interval runs from the first pending event and only while events are pending")
    func interval() {
        let h = harness()
        h.writer.start()
        h.advance(600_000)
        #expect(h.signals() == 0)

        h.track()
        h.advance(59_000)
        #expect(h.signals() == 0)
        h.track()
        h.advance(1_001)
        #expect(h.signals() == 1)

        h.advance(600_000)
        #expect(h.signals() == 0)
    }

    @Test("the interval starts at process start when events were left over")
    func intervalAtStart() {
        let h = harness()
        _ = h.eventStore.append(#"{"type":"track","message_id":"old","timestamp":1}"#)
        h.writer.start()
        h.advance(60_001)

        #expect(h.signals() == 1)
    }

    @Test("any flush cancels the interval")
    func flushCancelsInterval() {
        let h = harness()
        h.writer.start()
        h.track()
        h.advance(30_000)
        h.writer.flush()
        h.advance(1)
        #expect(h.signals() == 1)

        h.advance(40_000)
        #expect(h.signals() == 0)
    }

    @Test("backgrounding flushes and syncs")
    func backgroundFlush() {
        let h = harness()
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.track()
        h.runCurrent()

        h.test.lifecycleSource.moveToBackground()
        h.runCurrent()

        #expect(h.signals() == 1)
        #expect(h.eventStore.syncCount >= 1)
    }

    @Test("the network coming back flushes only while events are pending")
    func networkRegained() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        h.test.networkMonitor.setConnected(false)
        h.test.networkMonitor.setConnected(true)
        h.runCurrent()
        #expect(h.signals() == 0)

        h.track()
        h.runCurrent()
        h.test.networkMonitor.setConnected(false)
        h.test.networkMonitor.setConnected(true)
        h.runCurrent()
        #expect(h.signals() == 1)
    }

    @Test("an immediate event flushes after it is stored, matched exactly")
    func immediateEvent() {
        let h = harness { $0.flush.immediateEvents = ["Purchase Completed"] }
        h.writer.start()
        h.track("purchase completed")
        h.runCurrent()
        #expect(h.signals() == 0)

        h.track("Purchase Completed")
        h.runCurrent()

        #expect(h.signals() == 1)
        #expect(h.eventStore.closedSegments().count == 1)
        #expect(
            h.eventStore.segmentLines(0).map { h.field($0, "event") } == ["purchase completed", "Purchase Completed"])
        #expect(h.logged(.debug, containing: "Immediate event \"Purchase Completed\""))
    }

    @Test("the name that counts is the final one, after the hooks")
    func immediateAfterHooks() {
        let h = harness {
            $0.flush.immediateEvents = ["Order Placed"]
            $0.beforeSend = [
                { event in
                    guard var track = event as? TrackEvent else { return event }
                    track.name = "Order Placed"
                    return track
                }
            ]
        }
        h.writer.start()
        h.track("Checkout")
        h.runCurrent()

        #expect(h.signals() == 1)
    }

    @Test("flush includes every earlier event")
    func flushIncludesEarlier() {
        let h = harness { $0.flush.at = 100 }
        h.writer.start()
        for i in 0..<3 { h.track("E\(i)") }
        h.writer.flush()
        h.track("After")
        h.runCurrent()

        #expect(h.eventStore.closedSegments().count == 1)
        #expect(h.eventStore.segmentLines(0).count == 3)
        #expect(h.eventStore.openSegment.count == 1)
    }

    @Test("many flushes during an upload collapse into one signal")
    func conflatedSignal() {
        let h = harness()
        h.writer.start()
        for _ in 0..<10 { h.writer.flush() }
        h.runCurrent()

        #expect(h.signals() == 1)
    }

    // MARK: app lifecycle events

    static let installed = InstalledApp(
        version: "1.4.0", build: "140", installTime: Date(epochMillis: 1_000), updateTime: Date(epochMillis: 1_000))

    @Test("foreground and background produce the decided events, automatic and inside the session")
    func lifecycleEvents() {
        let h = harness()
        h.test.processFacts.installed = Self.installed
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()
        h.test.lifecycleSource.moveToBackground()
        h.runCurrent()
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()

        #expect(
            h.names() == [
                "Session Started", "Application Installed", "Application Opened", "Application Backgrounded",
                "Application Opened",
            ])
        #expect(Set(h.sources()) == ["auto"])
        let flushed = h.eventStore.closedSegments().flatMap { h.eventStore.segmentLines($0) }
        #expect(h.field(flushed.last ?? "", "event") == "Application Backgrounded")
        #expect(h.test.lifecycleSource.starts == 1)
    }

    @Test("a foreground seen at startup and replayed as a message opens once")
    func replayedForeground() {
        let h = WriterHarness(lifecycleSource: FakeLifecycleSource(foreground: true))
        h.writer.start()
        h.runCurrent()
        h.test.lifecycleSource.replayForeground()
        h.runCurrent()

        #expect(h.names() == ["Session Started", "Application Opened"])
    }

    @Test("each type follows its gate")
    func gates() {
        let h = harness { $0.autocapture.enabled = [.installUpdate] }
        h.test.processFacts.installed = Self.installed
        h.writer.start()
        h.runCurrent()
        h.test.lifecycleSource.moveToForeground()
        h.test.lifecycleSource.moveToBackground()
        h.runCurrent()

        #expect(h.names() == ["Application Installed"])
    }

    @Test("nothing is created while not collecting, but the version record is written")
    func versionRecordWhileOff() {
        let h = harness()
        h.test.processFacts.installed = Self.installed
        h.writer.start()
        h.runCurrent()
        h.flags.stopCollecting()
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()

        #expect(h.names().isEmpty)
        #expect(h.deviceStore.state?.lastBuild == "140")
    }

    // MARK: session events

    @Test("foreground, the first event and a long background produce the session events in order")
    func sessionEvents() {
        let h = harness { $0.autocapture.enabled = [.sessions] }
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.track("Opened")
        h.runCurrent()
        h.test.lifecycleSource.moveToBackground()
        h.runCurrent()
        h.pass(600_000)
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()

        #expect(h.names() == ["Session Started", "Opened", "Session Ended"])
    }

    @Test("a reset ends the session as the previous user, after earlier events")
    func resetEndsSession() {
        let h = harness { $0.autocapture.enabled = [.sessions] }
        h.writer.start()
        h.test.lifecycleSource.moveToForeground()
        h.runCurrent()
        _ = h.identity.identify("user-42", traits: [:])
        h.track("Before")
        h.identity.reset()
        h.track("After")
        h.runCurrent()

        #expect(h.names() == ["Session Started", "Before", "Session Ended", "Session Started", "After"])
        #expect(h.field(h.lines()[2], "user_id") == "user-42")
    }

    @Test("an unexpected failure is logged and the writer goes on")
    func unexpectedFailure() {
        let h = harness()
        h.writer.start()
        h.runCurrent()
        // An identity that was never resolved cannot happen in the SDK; here it makes the step fail.
        _ = h.writer.enqueue(
            CapturedEvent(
                kind: .track, name: "Broken", values: [:], source: .app, messageId: "x",
                timestamp: Date(epochMillis: 0),
                identity: IdentityRef(), callTime: .none))
        h.track("Fine")
        h.runCurrent()

        #expect(h.names() == ["Fine"])
        #expect(h.logged(.error, containing: Code.workerFailed.rawValue))
    }
}

/// The locked device of iOS Disk 1, the state Android never has.
@Suite("Writer on a locked device")
struct WriterLockedTests {
    @Test("events tracked while locked wait in the channel and are written in order after the unlock")
    func heldWhileLocked() {
        let h = WriterHarness()
        h.writer.start()
        h.track("Before")
        h.runCurrent()

        h.test.lifecycleSource.lockProtectedData()
        h.runCurrent()
        #expect(h.writer.isLocked)
        #expect(h.eventStore.suspendCount == 1)
        h.track("Held 1")
        h.writer.flush()
        h.track("Held 2")
        h.runCurrent()
        #expect(h.names() == ["Before"])
        #expect(h.signals() == 0)

        h.test.lifecycleSource.unlockProtectedData()
        h.runCurrent()

        #expect(!h.writer.isLocked)
        #expect(h.names() == ["Before", "Held 1", "Held 2"])
        #expect(h.signals() == 1)
        #expect(h.eventStore.segmentLines(0).count == 2)
    }

    @Test("an unlock in a process that started locked loads the stores then, and the events get their identity")
    func startedLocked() {
        let fileSystem = FakeFileSystem()
        fileSystem.locked = true
        let eventStore = InMemoryEventStore()
        eventStore.locked = true
        let h = WriterHarness(
            eventStore: eventStore,
            lifecycleSource: FakeLifecycleSource(foreground: true, protectedDataAvailable: false),
            fileSystem: fileSystem)
        h.writer.start()
        _ = h.identity.identify("user-42", traits: [:])
        h.track("Early")
        h.runCurrent()

        #expect(h.writer.isStarted)
        #expect(!h.writer.isReady)
        #expect(h.writer.isLocked)
        // No file exists yet, which a locked device can still tell: the id is minted in memory and
        // written at the unlock; a file that exists but cannot be read would give "" (iOS Disk 1).
        let early = h.identity.deviceId
        #expect(early != "")
        #expect(h.lines().isEmpty)
        #expect(h.test.lifecycleSource.starts == 1)
        fileSystem.locked = false
        #expect(h.keyValueStore.read(DeviceStore.fileName) == .missing)

        eventStore.locked = false
        h.test.lifecycleSource.unlockProtectedData()
        h.runCurrent()

        #expect(h.writer.isReady)
        #expect(!h.writer.isLocked)
        #expect(h.names() == ["Session Started", "Application Opened", "Early"])
        #expect(h.field(h.lines()[2], "user_id") == "user-42")
        #expect(h.field(h.lines()[2], "device_id") == early)
        #expect(h.identity.deviceId == early)
        guard case .present(let device) = h.keyValueStore.read(DeviceStore.fileName) else {
            Issue.record("device.json was not written after the unlock")
            return
        }
        #expect(device.contains(early))
    }

    @Test("a device file that exists but cannot be read gives an empty deviceId until the unlock")
    func existingFileLocked() throws {
        let root = TestPlatform.temporaryDirectory()
        let earlier = WriterHarness(storageRoot: root)
        earlier.writer.start()
        earlier.runCurrent()
        let real = earlier.identity.deviceId
        #expect(real != "")

        let fileSystem = FakeFileSystem()
        fileSystem.locked = true
        let h = WriterHarness(
            storageRoot: root, lifecycleSource: FakeLifecycleSource(foreground: false, protectedDataAvailable: false),
            fileSystem: fileSystem)
        h.writer.start()
        h.runCurrent()
        #expect(h.identity.deviceId == "")
        #expect(!h.consent.isOptedOut)

        fileSystem.locked = false
        h.test.lifecycleSource.unlockProtectedData()
        h.runCurrent()

        #expect(h.identity.deviceId == real)
        #expect(h.writer.isReady)
    }

    @Test("the protected-data messages pass a full channel")
    func bypassCapacity() {
        let h = WriterHarness()
        h.writer.start()
        h.runCurrent()
        h.test.lifecycleSource.lockProtectedData()
        h.runCurrent()
        for _ in 0..<1000 { h.track() }
        #expect(!h.track())

        h.test.lifecycleSource.unlockProtectedData()
        h.runCurrent()

        // The 1001st event's backpressure drop is reported by SDK Diagnostics at the first flush.
        let names = h.names()
        #expect(names.filter { $0 != Diagnostics.eventName }.count == 1000)
        #expect(names.contains(Diagnostics.eventName))
    }

    @Test("willTerminate syncs the events and writes the stores")
    func willTerminate() {
        let h = WriterHarness()
        h.writer.start()
        h.runCurrent()
        h.identity.register("plan", value: "pro")
        h.test.lifecycleSource.terminate()
        h.runCurrent()

        #expect(h.eventStore.syncCount == 1)
        guard case .present(let person) = h.keyValueStore.read(PersonStore.fileName) else {
            Issue.record("person.json missing")
            return
        }
        #expect(person.contains("\"plan\""))
        #expect(h.signals() == 0)
    }
}
