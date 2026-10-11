import Foundation
import Network
import RubiconCore

/// A small HTTP/1.1 server on `NWListener` (D15), the counterpart of MockWebServer: one connection
/// at a time, scripted responses in order, every request recorded with its headers and raw body.
/// Once the script is used up it answers `200` with an empty body. Each response closes the
/// connection, so a client sees a fresh connection per request.
///
/// ```swift
/// let server = try TestHTTPServer()
/// server.enqueue(.init(status: 429, headers: ["Retry-After": "120"]))
/// let url = server.url(path: "/v1/batch")
/// ...
/// let request = try #require(server.waitForRequest())
/// #expect(request.header("Content-Encoding") == "gzip")
/// server.stop()
/// ```
package final class TestHTTPServer: @unchecked Sendable {
    /// A scripted answer. `delayMillis` holds the response back (for timeout tests); `drop` closes
    /// the connection without answering (for the `io` failure kind).
    package struct Response: Sendable {
        package var status: Int
        package var headers: [String: String]
        package var body: Data
        package var delayMillis: Int
        package var drop: Bool

        package init(
            status: Int = 200, headers: [String: String] = [:], body: Data = Data(), delayMillis: Int = 0,
            drop: Bool = false
        ) {
            self.status = status
            self.headers = headers
            self.body = body
            self.delayMillis = delayMillis
            self.drop = drop
        }

        /// A response that closes the connection without any bytes.
        package static let dropped = Response(drop: true)
    }

    /// One received request.
    package struct RecordedRequest: Sendable {
        package var method: String
        package var path: String
        package var headers: [(name: String, value: String)]
        package var body: Data

        /// The first header with `name`, compared without regard to case.
        package func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    private struct State {
        var script: [Response] = []
        var fixed: [String: Response] = [:]
        var requests: [RecordedRequest] = []
        var connections: [NWConnection] = []
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.rubicon.analytics.testserver")
    // Guarded by `state`.
    private let state = Locked(State())
    private let requestArrived = DispatchSemaphore(value: 0)
    package let port: UInt16

    /// Starts listening on an ephemeral port of the loopback interface.
    package init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let readyPort = Locked<UInt16?>(nil)
        let failure = Locked<String?>(nil)
        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                readyPort.withLock { $0 = listener.port?.rawValue }
                ready.signal()
            case .failed(let error):
                failure.withLock { $0 = String(describing: error) }
                ready.signal()
            case .cancelled:
                failure.withLock { $0 = "cancelled" }
                ready.signal()
            default:
                break
            }
        }
        // The connection handler must be in place before `start`, or the listener fails with EINVAL;
        // `self` is not available yet, so the handler reaches it through a weak box set below.
        let owner = WeakBox<TestHTTPServer>()
        listener.newConnectionHandler = { connection in
            owner.value?.accept(connection)
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = readyPort.current else {
            listener.cancel()
            throw NSError(
                domain: "TestHTTPServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "listener did not become ready: \(failure.current ?? "timeout")"])
        }
        self.listener = listener
        self.port = port
        owner.value = self
    }

    /// `http://127.0.0.1:{port}{path}`.
    package func url(path: String = "/") -> URL {
        // The path is the test's own; a malformed one is a test bug.
        URL(string: "http://127.0.0.1:\(port)\(path)") ?? URL(fileURLWithPath: "/")
    }

    /// The host form the SDK's `host` setting takes.
    package var hostString: String { "http://127.0.0.1:\(port)" }

    package func enqueue(_ responses: Response...) {
        state.withLock { $0.script.append(contentsOf: responses) }
    }

    /// Always answers `path` with `response`, outside the script: a backend whose `/v1/config` says
    /// 404 while `/v1/batch` follows the script.
    package func respond(to path: String, with response: Response) {
        state.withLock { $0.fixed[path] = response }
    }

    /// The requests received so far, oldest first.
    package var requests: [RecordedRequest] { state.current.requests }

    /// Waits until a request beyond those already returned by earlier calls has arrived.
    package func waitForRequest(timeoutSeconds: Double = 5) -> RecordedRequest? {
        guard requestArrived.wait(timeout: .now() + timeoutSeconds) == .success else { return nil }
        return state.withLock { s in s.requests.last }
    }

    package func stop() {
        listener.cancel()
        state.withLock { s in
            for connection in s.connections { connection.cancel() }
            s.connections = []
        }
    }

    deinit {
        stop()
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        state.withLock { $0.connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                self.answer(connection, request)
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    private static func parse(_ buffer: Data) -> RecordedRequest? {
        guard let range = buffer.range(of: headerEnd) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        let length =
            headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }
            .flatMap { Int($0.1) } ?? 0
        let bodyStart = range.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return RecordedRequest(method: requestLine[0], path: requestLine[1], headers: headers, body: Data(body))
    }

    private func answer(_ connection: NWConnection, _ request: RecordedRequest) {
        let response: Response = state.withLock { s in
            s.requests.append(request)
            if let fixed = s.fixed[request.path] { return fixed }
            return s.script.isEmpty ? Response() : s.script.removeFirst()
        }
        requestArrived.signal()
        let send: @Sendable () -> Void = { [queue] in
            if response.drop {
                connection.cancel()
                return
            }
            var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
            var headers = response.headers
            headers["Content-Length"] = String(response.body.count)
            headers["Connection"] = "close"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"
            var data = Data(head.utf8)
            data.append(response.body)
            connection.send(
                content: data,
                completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + .milliseconds(50)) { connection.cancel() }
                })
        }
        if response.delayMillis > 0 {
            queue.asyncAfter(deadline: .now() + .milliseconds(response.delayMillis), execute: send)
        } else {
            send()
        }
    }

    // A weak reference the connection handler can hold before the server exists.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        // Written once, right after `init`, on the creating thread; read on the listener queue.
        weak var value: T?
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }
}
