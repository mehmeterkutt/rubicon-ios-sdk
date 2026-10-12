import Rubicon
import UIKit

/// The scenario screen the consumer apps share (step 8.1): one instance created at launch from the
/// launch environment, buttons for the verbs the UI tests drive, labels fed by the event observer.
/// The same file compiles in Swift 5 mode (`Swift5App`) and in Swift 6 mode with strict
/// concurrency and warnings as errors (`Swift6App`); `ObjCApp` has the same screen in Objective-C.
///
/// Launch environment: `RUBICON_HOST` (the test server, default `http://127.0.0.1:9`),
/// `RUBICON_RESET` (`1` deletes the SDK's files before the instance is created).
enum Scenario {
    static let storageDirectory = "rubicon"

    /// Creates the instance; call once, from `didFinishLaunching`.
    @MainActor
    static func makeAnalytics(observer: @escaping @Sendable (EventUpdate) -> Void) -> any Analytics {
        let environment = ProcessInfo.processInfo.environment
        if environment["RUBICON_RESET"] == "1" { reset() }
        var config = AnalyticsConfiguration(apiKey: "rk_consumer")
        config.host = environment["RUBICON_HOST"] ?? "http://127.0.0.1:9"
        config.debug = false
        config.flush.at = 100
        config.flush.intervalMs = 600_000
        config.logging.sendDiagnostics = false
        config.logging.eventObserver = observer
        config.logging.logger = SampleHooks.logger
        config.beforeSend = [SampleHooks.beforeSend]
        let analytics = RubiconAnalytics.make(configuration: config)
        SendableChecks.exercise(analytics)
        return analytics
    }

    /// Deletes `Application Support/rubicon`, so a launch starts as a fresh install.
    static func reset() {
        let fileManager = FileManager.default
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        try? fileManager.removeItem(at: support.appendingPathComponent(storageDirectory, isDirectory: true))
    }
}

/// The screen: counts of queued, sent and dropped events, the device id, a note, and the buttons.
final class ScenarioViewController: UIViewController {
    private let analytics: any Analytics
    private let queuedLabel = UILabel()
    private let sentLabel = UILabel()
    private let droppedLabel = UILabel()
    private let deviceLabel = UILabel()
    private let noteLabel = UILabel()
    private var queued = 0
    private var sent = 0
    private var dropped = 0

    init(analytics: any Analytics) {
        self.analytics = analytics
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [
            labelled(queuedLabel, "queued"), labelled(sentLabel, "sent"), labelled(droppedLabel, "dropped"),
            labelled(deviceLabel, "device-id"), labelled(noteLabel, "note"),
            button("Track", "track", #selector(track)),
            button("Flush", "flush", #selector(flush)),
            button("Second instance", "second-instance", #selector(secondInstance)),
            button("Opt out", "opt-out", #selector(optOut)),
            button("Opt in", "opt-in", #selector(optIn)),
        ])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
        ])
        deviceLabel.text = analytics.deviceId
        render()
    }

    /// The observer's update, on the main thread.
    func apply(_ update: EventUpdate) {
        switch update {
        case .queued: queued += 1
        case .sent(let ids): sent += ids.count
        case .dropped(let ids, _): dropped += ids.count
        }
        render()
    }

    private func render() {
        queuedLabel.text = "queued \(queued)"
        sentLabel.text = "sent \(sent)"
        droppedLabel.text = "dropped \(dropped)"
    }

    @objc private func track() {
        analytics.track("Button Tapped", properties: ["count": queued + 1, "flag": true])
    }

    @objc private func flush() {
        analytics.flush()
    }

    @objc private func secondInstance() {
        var other = AnalyticsConfiguration(apiKey: "rk_other")
        other.debug = false  // with debug on, a second make is a developer error and traps (iOS Configuration 2)
        let again = RubiconAnalytics.make(configuration: other)
        let same = (again as AnyObject) === (analytics as AnyObject)
        noteLabel.text = same ? "same instance" : "another instance"
    }

    @objc private func optOut() {
        analytics.optOut()
        noteLabel.text = analytics.isOptedOut ? "opted out" : "opted in"
    }

    @objc private func optIn() {
        analytics.optIn()
        noteLabel.text = analytics.isOptedOut ? "opted out" : "opted in"
    }

    private func labelled(_ label: UILabel, _ identifier: String) -> UILabel {
        label.accessibilityIdentifier = identifier
        label.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        label.adjustsFontSizeToFitWidth = true
        return label
    }

    private func button(_ title: String, _ identifier: String, _ action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
}
