import Foundation
import RubiconCore
import RubiconTesting
import Testing

/// `flushBlocking` with a report when it fails: the SDK's log lines (codes and messages, never
/// values) and the paths the test server received, so a stall on a CI runner can be read from the
/// log instead of guessed. The report waits for the transport's request timeout (20 s) so the line
/// that names the failure is in it.
enum FlushDiagnostics {
    static func flush(
        _ analytics: any Analytics, server: TestHTTPServer, messages: () -> [String], timeoutMs: Int64 = 10_000,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        let started = Date()
        if RubiconCore.flushBlocking(analytics, timeoutMs: timeoutMs) { return true }
        let before = messages().count
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && messages().count == before {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        let report =
            "flush did not finish in \(timeoutMs) ms; after \(elapsed) s the log has \(messages()) "
            + "and the server saw \(server.requests.map(\.path))"
        Issue.record(Comment(rawValue: report), sourceLocation: sourceLocation)
        return false
    }
}
