import Testing

/// The suites that touch process-wide state: the one `Analytics` instance (`resetForTests` shuts
/// down whatever exists) and `ScreenCapture.shared`, whose target the factory replaces. Swift
/// Testing runs suites in parallel, so two of them in flight at once reset each other; nested
/// here, they run one after another while every other suite still runs in parallel. The network
/// observer suite is here too: it holds real sockets, and on a three-core CI runner such suites
/// starved each other (`RealWorldSuites` in the core tests).
@Suite("Process-wide state", .serialized)
enum ProcessWideSuites {}
