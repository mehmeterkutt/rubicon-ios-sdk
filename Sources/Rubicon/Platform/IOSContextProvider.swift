import Foundation
import RubiconCore

#if canImport(UIKit)
    import UIKit
#endif

/// The `context` of events on iOS (Context 1 to 3, 6; iOS Context 1, 2).
///
/// - App values come from the bundle and the device model from `uname`, read once on the writer on
///   first need. The UIKit values (OS version, device type, screen) are main-actor isolated in
///   Swift 6, so they are read once on the main thread by `attach()`, which the factory calls at
///   creation: memory reads, no disk, no blocking (Android log 7.3 kept the worker; iOS cannot).
/// - `network.type` is the shared path monitor's cached value; `locale` and `timezone` are read per
///   event on the calling thread, from Foundation's own caches.
/// - Before the writer's first `refresh` the call-time values are `pending` with the timezone only.
/// - A disabled field is never read; a value that cannot be read is `nil` and omitted.
// The screen and UIKit values sit in a `Locked`; everything else is immutable or read per call.
final class IOSContextProvider: ContextProvider, @unchecked Sendable {
    struct MainThreadValues: Equatable, Sendable {
        var osVersion: String?
        var deviceType: String?
        var screenWidth: Int?
        var screenHeight: Int?
        var screenDensity: Double?
    }

    private let bundle: Bundle
    private let network: PathNetworkMonitor?
    private let mainValues = Locked<MainThreadValues?>(nil)
    private let ready = AtomicFlag()

    init(bundle: Bundle, network: PathNetworkMonitor?) {
        self.bundle = bundle
        self.network = network
    }

    /// Reads the UIKit values; on the main thread at once, else posted there without waiting.
    func attach() {
        if Thread.isMainThread {
            readMainThreadValues()
        } else {
            DispatchQueue.main.async { [self] in readMainThreadValues() }
        }
    }

    /// For tests on macOS, where UIKit is absent.
    func setMainThreadValues(_ values: MainThreadValues) {
        mainValues.withLock { $0 = values }
    }

    func staticValues(disabled: Set<ContextField>) -> StaticValues {
        let info = bundle.infoDictionary ?? [:]
        let main = mainValues.current
        func read<T>(_ field: ContextField, _ value: () -> T?) -> T? {
            if disabled.contains(field) { return nil }
            let read = value()
            if let text = read as? String, text.allSatisfy(\.isWhitespace) { return nil }
            return read
        }
        return StaticValues(
            appName: read(.appName) { (info["CFBundleName"] as? String) ?? (info["CFBundleDisplayName"] as? String) },
            appVersion: read(.appVersion) { info["CFBundleShortVersionString"] as? String },
            appBuild: read(.appBuild) { info["CFBundleVersion"] as? String },
            appNamespace: read(.appNamespace) { bundle.bundleIdentifier },
            deviceManufacturer: read(.deviceManufacturer) { Self.manufacturer },
            deviceModel: read(.deviceModel) { Self.machineIdentifier() },
            deviceType: read(.deviceType) { main?.deviceType },
            deviceIsEmulator: read(.deviceIsEmulator) { Self.isSimulator },
            osName: read(.osName) { Self.osName },
            osVersion: read(.osVersion) { main?.osVersion },
            screenWidth: read(.screenWidth) { main?.screenWidth },
            screenHeight: read(.screenHeight) { main?.screenHeight },
            screenDensity: read(.screenDensity) { main?.screenDensity })
    }

    func callTimeValues(disabled: Set<ContextField>) -> CallTimeValues {
        let timezone = disabled.contains(.timezone) ? nil : TimeZone.current.identifier
        guard ready.isSet else { return CallTimeValues(timezone: timezone, pending: true) }
        return CallTimeValues(
            networkType: disabled.contains(.networkType) ? nil : network?.networkType,
            locale: disabled.contains(.locale) ? nil : Self.currentLocale(), timezone: timezone)
    }

    func refresh(disabled: Set<ContextField>) {
        ready.set()
    }

    // MARK: - Sources

    static let manufacturer = "Apple"
    static let osName = "iOS"

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            return true
        #else
            return false
        #endif
    }

    /// The machine identifier, such as `iPhone16,2`, from `uname`.
    static func machineIdentifier() -> String? {
        var system = utsname()
        guard uname(&system) == 0 else { return nil }
        let machine = withUnsafeBytes(of: &system.machine) { bytes -> String in
            let data = bytes.prefix { $0 != 0 }
            return String(decoding: data, as: UTF8.self)
        }
        return machine.isEmpty ? nil : machine
    }

    /// The app's resolved language joined with the device region (iOS Context 1): `tr-TR`.
    static func currentLocale() -> String? {
        locale(
            preferredLocalization: Bundle.main.preferredLocalizations.first,
            region: (Locale.current as NSLocale).object(forKey: .countryCode) as? String)
    }

    static func locale(preferredLocalization: String?, region: String?) -> String? {
        guard let language = preferredLocalization, !language.isEmpty, language != "und" else { return nil }
        // A localization may already carry a region (`pt-BR`): keep it, never double it.
        if language.contains("-") { return language }
        guard let region, !region.isEmpty else { return language }
        return "\(language)-\(region)"
    }

    /// The short side first, in pixels (Android log 7.3: no orientation is implied).
    static func screen(width: Double, height: Double, scale: Double) -> (width: Int?, height: Int?, density: Double?) {
        let short = Int(min(width, height).rounded())
        let long = Int(max(width, height).rounded())
        return (short > 0 ? short : nil, long > 0 ? long : nil, scale > 0 ? scale : nil)
    }

    private func readMainThreadValues() {
        #if canImport(UIKit)
            // `attach` reaches here on the main thread only, which is what the actor requires.
            let values: MainThreadValues = MainActor.assumeIsolated {
                let device = UIDevice.current
                let type: String?
                switch device.userInterfaceIdiom {
                case .phone: type = "phone"
                case .pad: type = "tablet"
                case .tv: type = "tv"
                default: type = nil
                }
                let bounds = UIScreen.main.nativeBounds
                let screen = Self.screen(width: bounds.width, height: bounds.height, scale: UIScreen.main.scale)
                return MainThreadValues(
                    osVersion: device.systemVersion, deviceType: type, screenWidth: screen.width,
                    screenHeight: screen.height, screenDensity: screen.density)
            }
            mainValues.withLock { $0 = values }
        #endif
    }
}
