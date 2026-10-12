import Rubicon
import SwiftUI
import WidgetKit

/// The app extension of step 8.3 (iOS Queue 2 decision 2, point 4): a widget that creates the SDK
/// the way an app would and shows what it got. In an extension the factory returns the no-op
/// instance: `isOptedOut` is `true`, `deviceId` is empty, and no file is created under
/// `Application Support/rubicon`. Building this target also proves the SDK links into an
/// extension, where `UIApplication.shared` is unavailable at compile time.
struct ProbeEntry: TimelineEntry {
    let date: Date
    let isOptedOut: Bool
    let deviceId: String
    let filesCreated: Bool
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry {
        ProbeEntry(date: Date(), isOptedOut: true, deviceId: "", filesCreated: false)
    }

    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(Self.probe())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        completion(Timeline(entries: [Self.probe()], policy: .never))
    }

    /// Creates the SDK and reports the facts the extension test asserts.
    static func probe() -> ProbeEntry {
        var config = AnalyticsConfiguration(apiKey: "rk_widget")
        config.debug = false
        config.logging.sendDiagnostics = false
        let analytics = RubiconAnalytics.make(configuration: config)
        analytics.track("From Widget")
        analytics.flush()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let root = support?.appendingPathComponent("rubicon", isDirectory: true)
        let files = root.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return ProbeEntry(
            date: Date(), isOptedOut: analytics.isOptedOut, deviceId: analytics.deviceId, filesCreated: files)
    }
}

struct ProbeView: View {
    let entry: ProbeEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rubicon in a widget").font(.headline)
            Text("opted out: \(entry.isOptedOut ? "yes" : "no")")
            Text("device id: \(entry.deviceId.isEmpty ? "(empty)" : entry.deviceId)")
            Text("files: \(entry.filesCreated ? "created" : "none")")
        }
        .font(.caption)
        .accessibilityIdentifier("probe")
    }
}

@main
struct RubiconWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.rubicon.analytics.consumer.widget", provider: ProbeProvider()) { entry in
            if #available(iOS 17.0, *) {
                ProbeView(entry: entry).containerBackground(.background, for: .widget)
            } else {
                ProbeView(entry: entry).padding()
            }
        }
        .configurationDisplayName("Rubicon probe")
        .description("What the SDK reports inside an app extension.")
    }
}
