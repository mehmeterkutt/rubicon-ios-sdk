import Foundation
import RubiconCore

/// `flushBlocking` with a report when it fails: what the flush waits for, the SDK's log lines (codes
/// and messages, never values), the paths and the connection events of the test server, and on
/// macOS the frames of the SDK's own threads (`sample`), so a stall on a CI runner can be read from
/// the log instead of guessed. The report waits for the transport's resource timeout so the line
/// that names the failure is in it. The caller records the report as an issue.
package enum FlushReport {
    /// `nil` when the flush finished in time; otherwise the report.
    package static func flush(
        _ analytics: any Analytics, server: TestHTTPServer, messages: () -> [String], timeoutMs: Int64 = 10_000
    ) -> String? {
        let started = Date()
        if RubiconCore.flushBlocking(analytics, timeoutMs: timeoutMs) { return nil }
        let state = (analytics as? DefaultAnalytics)?.flushState ?? "not the default instance"
        let threads = sampleThreads()
        let before = messages().count
        let deadline = Date().addingTimeInterval(80)
        while Date() < deadline && messages().count == before {
            Thread.sleep(forTimeInterval: 0.1)
        }
        let elapsed = Int(Date().timeIntervalSince(started))
        return "flush did not finish in \(timeoutMs) ms (\(state)); after \(elapsed) s the log has \(messages()), "
            + "the server saw \(server.requests.map(\.path)) with events \(server.connectionEvents)"
            + threads
    }

    /// The SDK's frames in every thread of this process, on macOS; empty elsewhere or when `sample`
    /// is unavailable.
    private static func sampleThreads() -> String {
        #if os(macOS)
            let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                "rubicon-sample-\(getpid()).txt")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
            process.arguments = [String(getpid()), "1", "-file", output.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return "; sample unavailable"
            }
            process.waitUntilExit()
            guard let text = try? String(contentsOf: output, encoding: .utf8) else { return "; sample unreadable" }
            try? FileManager.default.removeItem(at: output)
            let interesting = text.split(separator: "\n").filter { line in
                // Frames, not the binary image table at the end.
                guard !line.contains("/System/"), !line.contains("/Users/"), !line.contains("/Applications/")
                else { return false }
                return line.contains("Thread_") || line.contains("Rubicon") || line.contains("CFNetwork")
                    || line.contains("semaphore") || line.contains("lock") || line.contains("kevent")
                    || line.contains("__select") || line.contains("connect")
            }
            return "; threads:\n" + interesting.prefix(120).joined(separator: "\n")
        #else
            return ""
        #endif
    }
}
