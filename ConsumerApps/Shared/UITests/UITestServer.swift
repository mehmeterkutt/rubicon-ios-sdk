import Foundation
import zlib

/// The UI test runner's HTTP server (step 8.1): the counterpart of the package's `TestHTTPServer`,
/// repeated here because a UI test bundle links products, not package targets. It lives in the
/// runner process, so it outlives the app under test: a batch the first launch stored arrives here
/// after the second launch. Scripted answers per path, every request kept.
final class UITestServer: @unchecked Sendable {
    struct Response {
        var status = 200
        var body = Data()
        var delaySeconds = 0.0
    }

    struct Request {
        var method: String
        var path: String
        var headers: [(name: String, value: String)]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        /// The events of a `/v1/batch` body, gzip or plain.
        func events() -> [[String: Any]] {
            let bytes = header("Content-Encoding") == "gzip" ? (try? UITestServer.gunzip(body)) ?? Data() : body
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                let batch = object["batch"] as? [[String: Any]]
            else { return [] }
            return batch
        }

        /// The event names of a `/v1/batch` body.
        func eventNames() -> [String] {
            events().map { ($0["event"] as? String) ?? ($0["type"] as? String) ?? "?" }
        }
    }

    private let listening: Int32
    // A byte written here ends the accepting thread; `accept` cannot be woken any other way.
    private let wake: (read: Int32, write: Int32)
    private let lock = NSLock()
    private var fixed: [String: Response] = [:]
    private var recorded: [Request] = []
    private var connections: Set<Int32> = []
    private var stopped = false
    // Signalled once the accepting thread has closed the listening socket.
    private let acceptEnded = DispatchSemaphore(value: 0)
    let port: UInt16

    /// Listens on an ephemeral loopback port with POSIX sockets, as the package's server does: the
    /// `NWListener` version did not become ready or accept connections on the CI simulator.
    init() throws {
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
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw Self.error("bind or listen", code)
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
        let owner = WeakBox()
        owner.server = self
        let thread = Thread { [acceptEnded, wake] in
            Self.acceptLoop(fd, wake: wake, owner: owner, ended: acceptEnded)
        }
        thread.name = "com.rubicon.analytics.uitestserver.accept"
        thread.start()
    }

    /// The `host` setting of the SDK.
    var hostString: String { "http://127.0.0.1:\(port)" }

    /// Always answers `path` with `response`.
    func respond(to path: String, with response: Response) {
        lock.lock()
        fixed[path] = response
        lock.unlock()
    }

    var requests: [Request] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// The `/v1/batch` uploads received so far.
    var uploads: [Request] { requests.filter { $0.path == "/v1/batch" } }

    /// Waits until `count` uploads have arrived.
    func waitForUploads(_ count: Int, seconds: Double = 20) -> [Request] {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let current = uploads
            if current.count >= count { return current }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return uploads
    }

    /// Stops accepting and shuts every open connection; the threads close their own descriptors.
    func stop() {
        lock.lock()
        let first = !stopped
        let open = connections
        stopped = true
        lock.unlock()
        guard first else { return }
        var byte: UInt8 = 1
        _ = write(wake.write, &byte, 1)
        for fd in open { shutdown(fd, SHUT_RDWR) }
        _ = acceptEnded.wait(timeout: .now() + 2)
    }

    deinit { stop() }

    private static func acceptLoop(
        _ listening: Int32, wake: (read: Int32, write: Int32), owner: WeakBox, ended: DispatchSemaphore
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
            guard let server = owner.server, server.adopt(client) else {
                close(client)
                return
            }
        }
    }

    private func adopt(_ fd: Int32) -> Bool {
        lock.lock()
        let accepted = !stopped
        if accepted { connections.insert(fd) }
        lock.unlock()
        guard accepted else { return false }
        Self.setOption(fd, SO_NOSIGPIPE)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let owner = WeakBox()
        owner.server = self
        let thread = Thread {
            if let server = owner.server {
                server.serve(fd)
            } else {
                close(fd)
            }
        }
        thread.name = "com.rubicon.analytics.uitestserver.connection"
        thread.start()
        return true
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.lock()
            connections.remove(fd)
            lock.unlock()
            close(fd)
        }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var parsed: Request?
        while parsed == nil {
            let count = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if count <= 0 { return }
            buffer.append(contentsOf: chunk[0..<count])
            parsed = Self.parse(buffer)
        }
        guard let request = parsed else { return }
        lock.lock()
        recorded.append(request)
        let response = fixed[request.path] ?? Response()
        lock.unlock()
        if response.delaySeconds > 0 { Thread.sleep(forTimeInterval: response.delaySeconds) }
        lock.lock()
        let gone = stopped
        lock.unlock()
        if gone { return }
        let head =
            "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
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
        shutdown(fd, SHUT_WR)
        Thread.sleep(forTimeInterval: 0.05)
    }

    private static let headerEnd = Data("\r\n\r\n".utf8)

    private static func parse(_ buffer: Data) -> Request? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard requestLine.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append(
                (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        let length =
            headers.first { $0.0.caseInsensitiveCompare("Content-Length") == .orderedSame }.flatMap { Int($0.1) } ?? 0
        let bodyStart = range.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        return Request(
            method: requestLine[0], path: requestLine[1], headers: headers,
            body: Data(buffer[bodyStart..<(bodyStart + length)]))
    }

    private static func setOption(_ fd: Int32, _ option: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, option, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func error(_ call: String, _ code: Int32) -> NSError {
        NSError(
            domain: "UITestServer", code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(call) failed with errno \(code)"])
    }

    /// `inflateInit2_` with the gzip window, as the package's test helper does.
    static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw NSError(domain: "gzip", code: Int(status)) }
        defer { inflateEnd(&stream) }
        var output = Data()
        let inputBytes = [UInt8](input)
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        try inputBytes.withUnsafeBufferPointer { inPointer in
            stream.next_in = UnsafeMutablePointer(mutating: inPointer.baseAddress)
            stream.avail_in = UInt32(inPointer.count)
            repeat {
                let produced: Int = chunk.withUnsafeMutableBufferPointer { outPointer in
                    stream.next_out = outPointer.baseAddress
                    stream.avail_out = UInt32(outPointer.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return outPointer.count - Int(stream.avail_out)
                }
                output.append(chunk, count: produced)
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                    throw NSError(domain: "gzip", code: Int(status))
                }
            } while status != Z_STREAM_END && stream.avail_in > 0
        }
        guard status == Z_STREAM_END else { throw NSError(domain: "gzip", code: Int(status)) }
        return output
    }

    private final class WeakBox: @unchecked Sendable {
        weak var server: UITestServer?
    }
}
