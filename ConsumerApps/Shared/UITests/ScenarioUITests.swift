import XCTest

/// The simulator scenarios of step 8.1, the same file in the three apps' UI test bundles: the app
/// is launched against the runner's server, driven through its accessibility identifiers, and the
/// server's record is the assertion. Offline to online is covered by the core integration tests on
/// the fake network monitor, since a simulator in CI has no switchable network.
@MainActor
final class ScenarioUITests: XCTestCase {
    // `setUpWithError` and `tearDown` override nonisolated methods; the server is created and
    // stopped there and used from the main-actor test methods.
    private nonisolated(unsafe) var server: UITestServer!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try UITestServer()
        server.respond(to: "/v1/config", with: .init(status: 404))
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    private func launch(reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["RUBICON_HOST"] = server.hostString
        app.launchEnvironment["RUBICON_RESET"] = reset ? "1" : "0"
        app.launch()
        XCTAssertTrue(app.buttons["track"].waitForExistence(timeout: 10))
        return app
    }

    private func label(_ app: XCUIApplication, _ identifier: String) -> String {
        app.staticTexts[identifier].label
    }

    private func waitForLabel(_ app: XCUIApplication, _ identifier: String, _ expected: String, seconds: Double = 20)
        -> Bool
    {
        let predicate = NSPredicate(format: "label == %@", expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: app.staticTexts[identifier])
        return XCTWaiter().wait(for: [expectation], timeout: seconds) == .completed
    }

    func testTrackAndFlushReachTheServerAndTheObserver() {
        let app = launch()
        XCTAssertEqual(label(app, "device-id").count, 36)

        app.buttons["track"].tap()
        app.buttons["track"].tap()
        app.buttons["track"].tap()
        app.buttons["flush"].tap()

        let uploads = server.waitForUploads(1)
        XCTAssertEqual(uploads.count, 1)
        let names = uploads.flatMap { $0.eventNames() }
        XCTAssertEqual(names.filter { $0 == "Button Tapped" }.count, 3)
        XCTAssertTrue(names.contains("Application Opened"), "\(names)")
        // The sample beforeSend tags app events with the client (step 8.2).
        let tagged = uploads.flatMap { $0.events() }.filter { $0["event"] as? String == "Button Tapped" }
        XCTAssertEqual(tagged.count, 3)
        for event in tagged {
            let client = (event["properties"] as? [String: Any])?["client"] as? String
            XCTAssertTrue(client == "swift" || client == "objc", "\(String(describing: client))")
        }
        XCTAssertEqual(uploads[0].header("Authorization"), "Bearer rk_consumer")
        XCTAssertTrue(
            waitForLabel(app, "sent", "sent \(names.count)"), "sent label \(label(app, "sent")) for \(names)")
        XCTAssertEqual(label(app, "dropped"), "dropped 0")
    }

    func testEventsSurviveAProcessKillAndTheNextLaunchSendsThem() {
        let first = launch()
        first.buttons["track"].tap()
        first.buttons["track"].tap()
        XCTAssertTrue(queuedCount(first, atLeast: 2) >= 2, "queued label \(label(first, "queued"))")
        let deviceId = label(first, "device-id")
        first.terminate()
        XCTAssertTrue(server.uploads.isEmpty, "nothing was uploaded before the kill")

        let second = launch(reset: false)
        XCTAssertEqual(label(second, "device-id"), deviceId, "the same installation")
        second.buttons["flush"].tap()

        let names = server.waitForUploads(1).flatMap { $0.eventNames() }
        XCTAssertEqual(names.filter { $0 == "Button Tapped" }.count, 2, "the first launch's events: \(names)")
        XCTAssertEqual(names.filter { $0 == "Application Opened" }.count, 2, "one per launch: \(names)")
    }

    func testBackgroundingFlushesInsideTheBackgroundTask() {
        let app = launch()
        app.buttons["track"].tap()

        XCUIDevice.shared.press(.home)
        let uploads = server.waitForUploads(1, seconds: 30)
        app.activate()

        XCTAssertEqual(uploads.count, 1, "the background flush ran without a flush call")
        let names = uploads.flatMap { $0.eventNames() }
        XCTAssertTrue(names.contains("Button Tapped"), "\(names)")
        XCTAssertTrue(names.contains("Application Backgrounded"), "\(names)")
    }

    func testAnExpiredBackgroundTaskLeavesTheBatchOnDiskForTheNextAttempt() {
        // The server holds the answer longer than the background budget: the task expires, the
        // request is cancelled, nothing is lost, and the next trigger sends the batch again.
        server.respond(to: "/v1/batch", with: .init(status: 200, delaySeconds: 240))
        let app = launch()
        app.buttons["track"].tap()

        XCUIDevice.shared.press(.home)
        let firstAttempt = server.waitForUploads(1, seconds: 30)
        XCTAssertEqual(firstAttempt.count, 1, "the background flush started")
        // Wait past the simulator's background budget for the expiration handler.
        Thread.sleep(forTimeInterval: 40)
        server.respond(to: "/v1/batch", with: .init(status: 200))
        app.activate()
        XCTAssertTrue(app.buttons["flush"].waitForExistence(timeout: 10), "the app is alive after the expiration")
        app.buttons["flush"].tap()

        let uploads = server.waitForUploads(2, seconds: 60)
        XCTAssertEqual(uploads.count, 2, "the batch was sent again after the cancelled attempt")
        XCTAssertEqual(
            uploads[0].eventNames().filter { $0 == "Button Tapped" }.count,
            uploads[1].eventNames().filter { $0 == "Button Tapped" }.count, "the same batch")
    }

    func testASecondInstanceIsTheFirstAndConsentToggles() {
        let app = launch()

        app.buttons["second-instance"].tap()
        XCTAssertEqual(label(app, "note"), "same instance")
        app.buttons["opt-out"].tap()
        XCTAssertEqual(label(app, "note"), "opted out")
        app.buttons["track"].tap()
        app.buttons["flush"].tap()
        app.buttons["opt-in"].tap()
        XCTAssertEqual(label(app, "note"), "opted in")
        app.buttons["track"].tap()
        app.buttons["flush"].tap()

        let names = server.waitForUploads(1).flatMap { $0.eventNames() }
        XCTAssertEqual(names.filter { $0 == "Button Tapped" }.count, 1, "the opted-out tap never existed: \(names)")
    }

    /// The queued count already includes the automatic events; this reads the label's number.
    private func queuedCount(_ app: XCUIApplication, atLeast minimum: Int) -> Int {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let text = label(app, "queued")
            if let number = Int(text.split(separator: " ").last ?? ""), number >= minimum { return number }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return Int(label(app, "queued").split(separator: " ").last ?? "") ?? -1
    }
}
