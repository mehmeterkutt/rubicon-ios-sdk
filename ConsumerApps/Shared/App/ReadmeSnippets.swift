import Rubicon
import UIKit

/// The README's Swift snippets, compiled in Swift 6 mode with strict concurrency and warnings as
/// errors by `Swift6App` (step 8.5). When the README changes, this file changes with it; a snippet
/// that no longer compiles fails the consumer build.
enum ReadmeSnippets {
    static func quickStart() -> any Analytics {
        var config = AnalyticsConfiguration(apiKey: "rk_live_...")
        config.host = "https://analytics.example.com"
        config.debug = false  // the README's instance; this app already created the real one
        let analytics = RubiconAnalytics.make(configuration: config)

        analytics.track("Purchase Completed", properties: ["amount": 49.90, "currency": "USD"])
        analytics.screen("Checkout")
        analytics.identify("user-42", traits: ["plan": "pro"])
        return analytics
    }

    static func firebaseQualification(_ config: AnalyticsConfiguration) {
        let analytics: Rubicon.Analytics = RubiconAnalytics.make(configuration: config)
        _ = analytics
    }

    static func autocapture(_ config: inout AnalyticsConfiguration) {
        config.autocapture.enabled.remove(.screenViews)
        config.autocapture.enabled.insert(.deepLinks)
    }

    @MainActor
    static func deepLinks(_ analytics: any Analytics, _ context: UIOpenURLContext, _ userActivity: NSUserActivity) {
        analytics.trackDeepLink(context.url, referrer: context.options.sourceApplication)
        analytics.trackDeepLink(userActivity)
    }

    static func hooks(_ config: inout AnalyticsConfiguration) {
        config.beforeSend = [
            { event in
                guard var track = event as? TrackEvent else { return event }
                if track.name.hasPrefix("debug_") { return nil }
                track.properties["tenant"] = .string("acme")
                return track
            }
        ]
    }

    static func consent(_ config: inout AnalyticsConfiguration, consentGiven: Bool) {
        config.privacy.defaultConsent = .pending
        let analytics = RubiconAnalytics.make(configuration: config)
        if consentGiven { analytics.optIn() } else { analytics.optOut() }
        _ = analytics.isOptedOut
        analytics.reset()
        analytics.clearLocalData()
    }

    static func logging(_ config: inout AnalyticsConfiguration) {
        config.logging.level = .info
        config.logging.logger = { level, message, error in
            myLogger.log("\(level) \(message) \(error.map { "\($0)" } ?? "")")
        }
        config.logging.eventObserver = { update in
            switch update {
            case .queued(let event): print("stored", event.messageId)
            case .sent(let ids): print("sent", ids.count)
            case .dropped(let ids, let reason): print("dropped", ids.count, reason)
            @unknown default: break
            }
        }
        config.logging.sendDiagnostics = false
        config.network.headers = ["X-Gateway-Token": "token"]
        config.context.disabledFields = [.locale]
    }

    private enum MyLogger {
        static func log(_ line: String) {}
    }

    private static let myLogger = MyLogger.self
}

final class PaymentFlowViewController: UIViewController, ScreenNamed {
    static let screenName = "checkout"
}

final class SessionDelegate: NSObject, URLSessionTaskDelegate {
    let observer: RubiconNetworkObserver

    init(analytics: any Analytics) {
        observer = RubiconNetworkObserver(analytics: analytics, hosts: ["api.example.com", "*.cdn.example.com"])
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        observer.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        observer.urlSession(session, task: task, didCompleteWithError: error)
    }
}
