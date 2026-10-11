import Testing

@testable import Rubicon
@testable import RubiconCore

/// Runs on the simulator (plan section 5); on macOS it only proves the target builds and links.
@Suite("Rubicon target")
struct RubiconTargetTests {
    @Test("the module builds and links against the core")
    func importsCore() {
        #expect(SDKVersion.current.isEmpty == false)
    }
}
