import Foundation
import RubiconCore

/// A small HTTP/1.1 server on POSIX sockets (D15, revised in the plan's log on 2026-10-12: the
/// `NWListener` version failed to become ready and to accept connections on the CI simulator), the
/// counterpart of MockWebServer: scripted responses in order, every request recorded with its
/// headers and raw body. Once the script is used up it answers `200` with an empty body. Each
/// response closes the connection, so a client sees a fresh connection per request.
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
        /// The open connections, shut down by `stop`; each serving thread closes its own.
        var connections: Set<Int32> = []
        var stopped = false
        /// What happened on the wire, for a report: accepted, bytes, parsed, answered, closed.
        var events: [String] = []
    }

    private let listening: Int32
    // A byte written here ends the accepting thread; `accept` cannot be woken any other way.
    private let wake: (read: Int32, write: Int32)
    // Guarded by `state`.
    private let state = Locked(State())
    private let requestArrived = DispatchSemaphore(value: 0)
    private let born = Date()
    // Signalled once the accepting thread has closed the listening socket.
    private let acceptEnded = DispatchSemaphore(value: 0)
    package let port: UInt16

    /// Starts listening on an ephemeral port of the loopback interface. Accepting and serving run on
    /// plain threads, never on a dispatch queue, because they block.
    package init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.error("socket", errno) }
        Self.setOption(fd, SO_REUSEADDR)
        Self.setOption(fd, SO_NOSIGPIPE)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw Self.error("bind", code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Self.error("listen", code)
        }
        var assigned = sockaddr_in()
        var assignedLength = length
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &assignedLength) }
        }
        guard named == 0 else {
            let code = errno
            close(fd)
            throw Self.error("getsockname", code)
        }
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else {
            let code = errno
            close(fd)
            throw Self.error("pipe", code)
        }
        listening = fd
        wake = (ends[0], ends[1])
        port = UInt16(bigEndian: assigned.sin_port)
        let owner = WeakBox(self)
        let thread = Thread { [acceptEnded, wake] in
            Self.acceptLoop(fd, wake: wake, owner: owner, ended: acceptEnded)
        }
        thread.name = "com.rubicon.analytics.testserver.accept"
        thread.start()
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

    /// The connection events so far, with seconds since the server started; for a failure report.
    package var connectionEvents: [String] { state.current.events }

    private func note(_ text: String) {
        let at = String(format: "%.3f", Date().timeIntervalSince(born))
        state.withLock { $0.events.append("\(at)s \(text)") }
    }

    /// Waits until a request beyond those already returned by earlier calls has arrived.
    package func waitForRequest(timeoutSeconds: Double = 5) -> RecordedRequest? {
        guard requestArrived.wait(timeout: .now() + timeoutSeconds) == .success else { return nil }
        return state.withLock { s in s.requests.last }
    }

    /// Stops accepting and shuts every open connection; the threads close their own descriptors.
    package func stop() {
        let connections: Set<Int32>? = state.withLock { s in
            if s.stopped { return nil }
            s.stopped = true
            return s.connections
        }
        guard let connections else { return }
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
        for fd in connections { shutdown(fd, SHUT_RDWR) }
        // Once this returns the port refuses connections, which the transport tests rely on.
        _ = acceptEnded.wait(timeout: .now() + 2)
    }

    deinit {
        stop()
    }

    // MARK: - Connections

    private static func acceptLoop(
        _ listening: Int32, wake: (read: Int32, write: Int32), owner: WeakBox<TestHTTPServer>, ended: DispatchSemaphore
    ) {
        defer {
            close(listening)
            close(wake.read)
            close(wake.write)
            ended.signal()
        }
        var fds = [
            pollfd(fd: listening, events: Int16(POLLIN), revents: 0),
            pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            let ready = poll(&fds, 2, -1)
            if ready < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }
            guard fds[0].revents != 0 else { continue }
            let client = accept(listening, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return
            }
            guard let server = owner.value, server.adopt(client) else {
                close(client)
                return
            }
        }
    }

    /// Registers the connection and serves it on its own thread; `false` once stopped.
    private func adopt(_ fd: Int32) -> Bool {
        let accepted = state.withLock { s -> Bool in
            if s.stopped { return false }
            s.connections.insert(fd)
            return true
        }
        guard accepted else { return false }
        note("accepted")
        Self.setOption(fd, SO_NOSIGPIPE)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let owner = WeakBox(self)
        let thread = Thread {
            if let server = owner.value {
                server.serve(fd)
            } else {
                close(fd)
            }
        }
        thread.name = "com.rubicon.analytics.testserver.connection"
        thread.start()
        return true
    }

    private func serve(_ fd: Int32) {
        defer {
            state.withLock { _ = $0.connections.remove(fd) }
            close(fd)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var parsed: RecordedRequest?
        while parsed == nil {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 {
                note("recv returned \(count) with errno \(errno) after \(buffer.count) bytes")
                return
            }
            buffer.append(contentsOf: chunk[0..<count])
            parsed = Self.parse(buffer)
        }
        guard let request = parsed else { return }
        note("parsed \(request.method) \(request.path)")
        let response: Response = state.withLock { s in
            s.requests.append(request)
            if let fixed = s.fixed[request.path] { return fixed }
            return s.script.isEmpty ? Response() : s.script.removeFirst()
        }
        requestArrived.signal()
        if response.delayMillis > 0 {
            Thread.sleep(forTimeInterval: Double(response.delayMillis) / 1000)
        }
        // A dropped answer, or a server stopped meanwhile, closes without a byte.
        if response.drop || state.current.stopped { return }
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
        var offset = 0
        while offset < data.count {
            let sent = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return send(fd, base + offset, data.count - offset, 0)
            }
            if sent <= 0 { return }
            offset += sent
        }
        note("answered \(response.status) for \(request.path)")
        shutdown(fd, SHUT_WR)
        // Let the client read the whole answer before the socket closes.
        Thread.sleep(forTimeInterval: 0.05)
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

    private static func setOption(_ fd: Int32, _ option: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func error(_ call: String, _ code: Int32) -> NSError {
        NSError(
            domain: "TestHTTPServer", code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(call) failed with errno \(code)"])
    }

    // A weak reference the threads hold, so a server that is no longer referenced can go away.
    private final class WeakBox<T: AnyObject>: @unchecked Sendable {
        // Written once in `init`; read on the serving threads.
        weak var value: T?
        init(_ value: T) { self.value = value }
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
