import Foundation
import RubiconCore

/// Process facts on iOS: the OS version for the User-Agent (HTTP 5), the app extension check (iOS
/// Queue 2) and the app's version, build and install dates (iOS Lifecycle 4, step 7.4).
final class IOSProcessFacts: ProcessFacts {
    private let bundle: Bundle

    init(bundle: Bundle) {
        self.bundle = bundle
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

    func installedApp() -> InstalledApp? {
        let info = bundle.infoDictionary ?? [:]
        return InstalledApp(
            version: info["CFBundleShortVersionString"] as? String, build: info["CFBundleVersion"] as? String,
            installTime: nil, updateTime: nil)
    }

    static func format(_ version: OperatingSystemVersion) -> String {
        version.patchVersion > 0
            ? "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            : "\(version.majorVersion).\(version.minorVersion)"
    }
}
