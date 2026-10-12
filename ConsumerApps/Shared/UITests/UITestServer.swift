import Foundation
import Network
import zlib

/// The UI test runner's HTTP server (step 8.1): the counterpart of the package's `TestHTTPServer`,
/// repeated here because a UI test bundle links products, not package targets. It lives in the
/// runner process, so it outlives the app under test: a batch the first launch stored arrives here
/// after the second launch. One connection at a time, scripted answers per path, every request kept.
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

        /// The event names of a `/v1/batch` body, gzip or plain.
        func eventNames() -> [String] {
            let bytes = header("Content-Encoding") == "gzip" ? (try? UITestServer.gunzip(body)) ?? Data() : body
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                let batch = object["batch"] as? [[String: Any]]
            else { return [] }
            return batch.map { ($0["event"] as? String) ?? ($0["type"] as? String) ?? "?" }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.rubicon.analytics.uitestserver")
    private let lock = NSLock()
    private var fixed: [String: Response] = [:]
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let box = PortBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                box.port = listener.port?.rawValue
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        let owner = WeakBox()
        listener.newConnectionHandler = { connection in owner.server?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        guard let port = box.port else {
            listener.cancel()
            throw NSError(domain: "UITestServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener not ready"])
        }
        self.listener = listener
        self.port = port
        owner.server = self
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

    func stop() {
        listener.cancel()
        lock.lock()
        for connection in connections { connection.cancel() }
        connections = []
        lock.unlock()
    }

    deinit { stop() }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections.append(connection)
        lock.unlock()
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

    private func answer(_ connection: NWConnection, _ request: Request) {
        lock.lock()
        recorded.append(request)
        let response = fixed[request.path] ?? Response()
        lock.unlock()
        let send: @Sendable () -> Void = { [queue] in
            var head =
                "HTTP/1.1 \(response.status) Status\r\nContent-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            head += ""
            var data = Data(head.utf8)
            data.append(response.body)
            connection.send(
                content: data,
                completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + .milliseconds(50)) { connection.cancel() }
                })
        }
        if response.delaySeconds > 0 {
            queue.asyncAfter(deadline: .now() + response.delaySeconds, execute: send)
        } else {
            send()
        }
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

    private final class PortBox: @unchecked Sendable {
        var port: UInt16?
    }

    private final class WeakBox: @unchecked Sendable {
        weak var server: UITestServer?
    }
}
