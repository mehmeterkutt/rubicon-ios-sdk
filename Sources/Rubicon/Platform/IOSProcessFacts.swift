import Foundation
import RubiconCore

/// Process facts on iOS: the OS version for the User-Agent (HTTP 5), the app extension check (iOS
/// Queue 2) and the app's version, build and install dates (iOS Lifecycle 4, step 7.4).
final class IOSProcessFacts: ProcessFacts {
    private let bundle: Bundle
    private let libraryURL: URL?

    /// `libraryURL` is the app's `Library` directory, whose creation date is the install time; tests
    /// pass their own.
    init(bundle: Bundle, libraryURL: URL? = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first)
    {
        self.bundle = bundle
        self.libraryURL = libraryURL
    }

    /// `17.5.1`, or `17.5` when the patch version is zero: the form `UIDevice.systemVersion` uses,
    /// from `ProcessInfo` so that the core's transport needs no UIKit.
    var osVersion: String {
        Self.format(ProcessInfo.processInfo.operatingSystemVersion)
    }

    /// `true` when the bundle is an app extension (`.appex`), where `UIApplication.shared` does not
    /// exist and the SDK does nothing (iOS Queue 2).
    var isAppExtension: Bool {
        bundle.bundlePath.hasSuffix(".appex")
    }

    /// On the writer, at the first foreground (iOS Lifecycle 4). The two creation dates are read
    /// through `URLResourceKey.creationDateKey`, a required-reason API of the file timestamp category
    /// declared with reason `C617.1`: the `Library` directory is created at installation and kept
    /// across updates, the app bundle is replaced on every update. A date that cannot be read is
    /// `nil`, and the core then produces no event and writes no record.
    func installedApp() -> InstalledApp? {
        let info = bundle.infoDictionary ?? [:]
        return InstalledApp(
            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
            installTime: libraryURL.flatMap(Self.creationDate), updateTime: Self.creationDate(of: bundle.bundleURL))
    }

    static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    static func format(_ version: OperatingSystemVersion) -> String {
        version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }
}
