import Testing

/// The suites that hold real threads and sockets: the `URLSession` transport against
/// `TestHTTPServer`, the core on real dispatch queues, the server and the GCD scheduler themselves.
/// Swift Testing runs suites in parallel; on a three-core CI runner these starved each other (a
/// request took 20 s to reach a loopback server, a flush did not finish in 10 s). Nested here, they
/// run one after another while the virtual-time suites still run in parallel.
@Suite("Real queues and sockets", .serialized)
enum RealWorldSuites {}
