import Foundation
import RubiconCore
import RubiconTesting
import Testing

/// `FlushReport` recorded as an issue at the caller's line.
enum FlushDiagnostics {
    static func flush(
        _ analytics: any Analytics, server: TestHTTPServer, messages: () -> [String], timeoutMs: Int64 = 10_000,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> Bool {
        guard let report = FlushReport.flush(analytics, server: server, messages: messages, timeoutMs: timeoutMs)
        else { return true }
        Issue.record(Comment(rawValue: report), sourceLocation: sourceLocation)
        return false
    }
}
