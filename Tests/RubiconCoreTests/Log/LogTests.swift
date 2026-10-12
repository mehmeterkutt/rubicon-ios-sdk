import Foundation
import RubiconTesting
import Testing

@testable import RubiconCore

@Suite("Log")
struct LogTests {
    let platform = RecordingLogger()
    let counted = Locked<[Code]>([])

    private func log(level: LogLevel = .debug, logger: RubiconLogger? = nil) -> Log {
        Log(level: level, logger: logger, platformLogger: platform.asLogger) { [counted] code in
            counted.withLock { $0.append(code) }
        }
    }

    @Test("a disabled line never builds its message", arguments: LogLevel.allCases)
    func levelGating(level: LogLevel) {
        let log = log(level: level)
        let built = Locked(0)
        func build(_ prefix: String) -> String {
            built.withLock {
                $0 += 1
                return "\(prefix)\($0)"
            }
        }

        log.debug { build("d") }
        log.info { build("i") }
        log.warn(.hostBlocked) { build("w") }
        log.error(.tlsFailed) { build("e") }

        let expected = [LogLevel.debug, .info, .warn, .error].filter { $0 >= level }.count
        #expect(built.current == expected)
        #expect(platform.lines.count == expected)
    }

    @Test("OFF logs nothing but still counts issues")
    func offCounts() {
        let log = log(level: .off)

        log.debug { "d" }
        log.info { "i" }
        log.warn(.hostBlocked) { "w" }
        log.error(.tlsFailed) { "e" }

        #expect(platform.messages.isEmpty)
        #expect(counted.current == [.hostBlocked, .tlsFailed])
    }

    @Test("isEnabled follows the order of the levels")
    func isEnabled() {
        let log = log(level: .warn)
        #expect(!log.isEnabled(.debug))
        #expect(!log.isEnabled(.info))
        #expect(log.isEnabled(.warn))
        #expect(log.isEnabled(.error))
        #expect(!log.isEnabled(.off))
    }

    @Test("warnings and errors start with their code and carry the error")
    func lineFormat() {
        let log = log()
        let cause = FileSystemError.io(code: 28, operation: "write")

        log.debug { "queued" }
        log.info { "host in use" }
        log.warn(.cleartextHost) { "host uses http" }
        log.error(.storageWriteFailed, cause) { "write failed" }

        #expect(
            platform.lines.map(\.description) == [
                "debug queued", "info host in use", "warn CLEARTEXT_HOST: host uses http",
                "error STORAGE_WRITE_FAILED: write failed",
            ])
        #expect(platform.lines.last?.error as? FileSystemError == cause)
    }

    @Test("the developer's logger replaces the platform logger")
    func developerLogger() {
        let developer = RecordingLogger()
        let log = log(logger: developer.asLogger)

        log.info { "hello" }

        #expect(developer.messages == ["hello"])
        #expect(platform.messages.isEmpty)
    }

    @Test("a code is logged at its level once, then at DEBUG, and always counted")
    func repeatLimit() {
        let log = log(level: .debug)

        for i in 0..<3 { log.warn(.hostBlocked) { "blocked \(i)" } }

        #expect(platform.lines.map(\.level) == [.warn, .debug, .debug])
        #expect(counted.current == [.hostBlocked, .hostBlocked, .hostBlocked])
    }

    @Test("at the default level only the first occurrence is visible and built")
    func defaultLevelRepeat() {
        let log = log(level: .warn)
        let built = Locked(0)

        for _ in 0..<3 {
            log.error(.tlsFailed) {
                built.withLock {
                    $0 += 1
                    return "tls \($0)"
                }
            }
        }

        #expect(platform.messages == ["TLS_FAILED: tls 1"])
        #expect(built.current == 1)
        #expect(counted.current.count == 3)
    }

    @Test("each code has its own limit, and a repeat key limits per key")
    func perCodeAndPerKey() {
        let log = log(level: .warn)

        log.warn(.hostBlocked) { "a" }
        log.warn(.cleartextHost) { "b" }
        log.warn(.hostBlocked) { "c" }
        log.warn(.propertyTruncated, repeatKey: "bio") { "bio" }
        log.warn(.propertyTruncated, repeatKey: "note") { "note" }
        log.warn(.propertyTruncated, repeatKey: "bio") { "bio again" }
        log.warn(.propertyTruncated) { "without key" }

        #expect(
            platform.messages == [
                "HOST_BLOCKED: a", "CLEARTEXT_HOST: b", "PROPERTY_TRUNCATED: bio", "PROPERTY_TRUNCATED: note",
                "PROPERTY_TRUNCATED: without key",
            ])
        #expect(counted.current.count == 7)
    }

    @Test("separate instances keep separate limits")
    func separateInstances() {
        log(level: .warn).warn(.hostBlocked) { "first" }
        log(level: .warn).warn(.hostBlocked) { "second" }
        #expect(platform.messages == ["HOST_BLOCKED: first", "HOST_BLOCKED: second"])
    }

    @Test("a logger reported as failed falls back to the platform logger once and says so once")
    func loggerFailure() {
        let developer = RecordingLogger()
        let log = log(logger: developer.asLogger)
        let failure = FileSystemError.permissionDenied

        log.info { "before" }
        log.callbacks.reportLoggerFailure(failure)
        log.callbacks.reportLoggerFailure(failure)
        log.info { "after" }

        #expect(developer.messages == ["before"])
        #expect(
            platform.messages == ["LOGGER_THREW: Custom logger threw; falling back to the default logger", "after"])
        #expect(platform.lines.first?.error as? FileSystemError == failure)
        #expect(counted.current == [.loggerThrew])
    }

    @Test("updates reach the observer until it is reported as failed, which logs one ERROR")
    func observer() {
        let log = log(level: .warn)
        let seen = Locked<[String]>([])

        log.callbacks.notifyObserver { seen.withLock { $0.append("queued") } }
        #expect(log.callbacks.isObserverEnabled)
        log.callbacks.reportObserverFailure(FileSystemError.notFound)
        log.callbacks.reportObserverFailure(FileSystemError.notFound)
        log.callbacks.notifyObserver { seen.withLock { $0.append("sent") } }

        #expect(seen.current == ["queued"])
        #expect(!log.callbacks.isObserverEnabled)
        #expect(platform.messages == ["OBSERVER_THREW: Event observer threw; it is switched off"])
        #expect(counted.current == [.observerThrew])
    }

    @Test("a failure reported from inside the failing callback is still written, as the wrapper reports it")
    func failureReportedInsideCallback() {
        let log = log(level: .warn)
        let developer = RecordingLogger()
        let withLogger = self.log(logger: developer.asLogger)

        // The wrapper's box reports while the failing callback is still on this thread's stack.
        log.callbacks.notifyObserver { log.callbacks.reportObserverFailure(FileSystemError.notFound) }
        withLogger.callbacks.log(.warn, "raises", nil)
        withLogger.callbacks.log(.warn, "second", nil)
        withLogger.callbacks.notifyObserver { withLogger.callbacks.reportLoggerFailure(FileSystemError.notFound) }

        #expect(!log.callbacks.isObserverEnabled)
        #expect(platform.messages.contains("OBSERVER_THREW: Event observer threw; it is switched off"))
        #expect(platform.messages.contains("LOGGER_THREW: Custom logger threw; falling back to the default logger"))
        #expect(developer.messages == ["raises", "second"])
    }

    @Test("a logger that logs through the SDK is ignored, without recursion, and the line still counts")
    func reentrantLogger() {
        let developer = RecordingLogger()
        let calls = Locked(0)
        let holder = Locked<Log?>(nil)
        let reentrant: RubiconLogger = { level, message, error in
            calls.withLock { $0 += 1 }
            developer.asLogger(level, message, error)
            holder.current?.warn(.hostBlocked) { "from inside the logger" }
        }
        let log = log(logger: reentrant)
        holder.withLock { $0 = log }

        log.info { "outside" }

        #expect(calls.current == 1)
        #expect(developer.messages == ["outside"])
        #expect(counted.current == [.hostBlocked])
    }

    @Test("an observer that logs or notifies again is ignored")
    func reentrantObserver() {
        let log = log(level: .debug)
        let calls = Locked(0)

        log.callbacks.notifyObserver {
            calls.withLock { $0 += 1 }
            log.info { "from inside the observer" }
            log.callbacks.notifyObserver { calls.withLock { $0 += 1 } }
        }

        #expect(calls.current == 1)
        #expect(platform.messages.isEmpty)
        #expect(!CallbackGuard.isInCallback)
    }

    @Test("only the thread inside the callback is affected")
    func otherThread() {
        let log = log(level: .debug)
        let done = DispatchSemaphore(value: 0)

        log.callbacks.notifyObserver {
            Thread {
                log.info { "from another thread" }
                done.signal()
            }.start()
            _ = done.wait(timeout: .now() + 5)
        }

        #expect(platform.messages == ["from another thread"])
    }

    @Test("lines from many threads all arrive and a code is logged at its level once")
    func manyThreads() {
        let log = log(level: .debug)
        let threads = 8
        let perThread = 500
        let group = DispatchGroup()
        for t in 0..<threads {
            group.enter()
            Thread {
                for i in 0..<perThread {
                    log.debug { "t\(t)-\(i)" }
                    log.warn(.hostBlocked) { "blocked" }
                }
                group.leave()
            }.start()
        }
        #expect(group.wait(timeout: .now() + 30) == .success)

        let lines = platform.lines
        #expect(lines.count == threads * perThread * 2)
        #expect(lines.filter { $0.level == .warn }.count == 1)
        #expect(counted.current.count == threads * perThread)
    }

    @Test("the no-op logger accepts anything and the code set has 42 iOS codes")
    func noOp() {
        noOpLogger(.error, "ignored", nil)
        #expect(Code.allCases.count == 42)
    }
}
