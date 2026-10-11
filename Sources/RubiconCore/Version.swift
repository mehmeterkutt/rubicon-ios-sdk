/// The SDK version, maintained by hand because SwiftPM generates nothing at build time (D5).
/// `Scripts/release.sh` updates it and CI fails when it differs from the tag being released.
enum SDKVersion {
    /// Semantic version of this build of the SDK, sent as `context.library.version`.
    static let current = "0.1.0"
}
