import Foundation
import RubiconCore

/// `flushBlocking` with a report when it fails: the SDK's log lines (codes and messages, never
/// values) and the paths the test server received, so a stall on a CI runner can be read from the
/// log instead of guessed. The report waits for the transport's request timeout (20 s) so the line
/// that names the failure is in it. The caller records the report as an issue.
package enum FlushReport {
    /// `nil` when the flush finished in time; otherwise the report.
    package static func flush(
        _ analytics: any Analytics, server: TestHTTPServer, messages: () -> [String], timeoutMs: Int64 = 10_000
    ) -> String? {
        let started = Date()
        if RubiconCore.flushBlocking(analytics, timeoutMs: timeoutMs) { return nil }
        let before = messages().count
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && messages().count == before {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        return "flush did not finish in \(timeoutMs) ms; after \(elapsed) s the log has \(messages()) "
            + "and the server saw \(server.requests.map(\.path))"
    }
}
