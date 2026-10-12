import Rubicon
import os

/// The hooks a client writes (step 8.2, iOS Public API 3 and 6), compiled in Swift 5 mode by
/// `Swift5App` and in Swift 6 mode with strict concurrency and warnings as errors by `Swift6App`:
/// a `beforeSend` that tags app events and drops debug events, and a logger on unified logging.
enum SampleHooks {
    static let clientName = "swift"

    /// Runs on the thread that called the SDK; copies the value, changes the copy, returns it.
    static let beforeSend: BeforeSend = { event in
        guard var track = event as? TrackEvent, track.source == .app else { return event }
        if track.name.hasPrefix("debug_") { return nil }
        track.properties["client"] = .string(clientName)
        return track
    }

    private static let log = Logger(subsystem: "com.rubicon.analytics.consumer", category: "sdk")

    /// Called from the SDK's queues; `Logger` is thread-safe.
    static let logger: RubiconLogger = { level, message, error in
        let type: OSLogType
        switch level {
        case .debug: type = .debug
        case .info: type = .info
        case .warn: type = .default
        case .error, .off: type = .error
        }
        if let error {
            log.log(level: type, "\(message, privacy: .public): \(String(describing: error), privacy: .public)")
        } else {
            log.log(level: type, "\(message, privacy: .public)")
        }
    }
}

/// Compile-time proof that the public types cross concurrency domains (iOS Public API 3): under
/// strict concurrency, a type that is not `Sendable` fails these lines; the instance is also sent
/// into a detached task and stored in an actor, as a Swift 6 client would.
enum SendableChecks {
    static func require<T: Sendable>(_: T.Type) {}

    static func types() {
        require((any Analytics).self)
        require(AnalyticsConfiguration.self)
        require(TrackEvent.self)
        require(ScreenEvent.self)
        require(IdentifyEvent.self)
        require(EventContext.self)
        require(PropertyValue.self)
        require(EventUpdate.self)
        require(DropReason.self)
        require(LogLevel.self)
        require(BeforeSend.self)
        require(RubiconLogger.self)
        require(EventObserver.self)
    }

    /// Uses the instance from a detached task and from an actor; both send one event.
    static func exercise(_ analytics: any Analytics) {
        types()
        Task.detached {
            analytics.track("Detached Task")
        }
        let holder = Holder(analytics: analytics)
        Task {
            await holder.fire()
        }
    }

    actor Holder {
        let analytics: any Analytics

        init(analytics: any Analytics) {
            self.analytics = analytics
        }

        func fire() {
            analytics.track("From Actor", properties: ["isolated": true])
        }
    }
}
