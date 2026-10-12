import Foundation
import RubiconTesting
import Testing

@testable import Rubicon
@testable import RubiconCore

/// The context provider of iOS Context 1 and 2 (step 7.3).
@Suite("IOSContextProvider")
struct IOSContextProviderTests {
    func provider() -> IOSContextProvider {
        IOSContextProvider(bundle: .main, network: nil)
    }

    @Test("the locale is the app's resolved language plus the device region, never doubled or undetermined")
    func localeRule() {
        #expect(IOSContextProvider.locale(preferredLocalization: "tr", region: "TR") == "tr-TR")
        #expect(IOSContextProvider.locale(preferredLocalization: "en", region: nil) == "en")
        #expect(IOSContextProvider.locale(preferredLocalization: "pt-BR", region: "PT") == "pt-BR")
        #expect(IOSContextProvider.locale(preferredLocalization: "und", region: "TR") == nil)
        #expect(IOSContextProvider.locale(preferredLocalization: nil, region: "TR") == nil)
        #expect(IOSContextProvider.locale(preferredLocalization: "", region: "TR") == nil)
    }

    @Test("the screen is the whole display in pixels, the short side first")
    func screenRule() {
        let portrait = IOSContextProvider.screen(width: 1179, height: 2556, scale: 3)
        let landscape = IOSContextProvider.screen(width: 2556, height: 1179, scale: 3)
        #expect(portrait.width == 1179 && portrait.height == 2556 && portrait.density == 3)
        #expect(landscape.width == 1179 && landscape.height == 2556)
        #expect(IOSContextProvider.screen(width: 0, height: 0, scale: 0) == (nil, nil, nil))
    }

    @Test("the machine identifier, the manufacturer, the OS name and the simulator flag")
    func constants() {
        let model = IOSContextProvider.machineIdentifier()
        #expect(model?.isEmpty == false)
        #expect(IOSContextProvider.manufacturer == "Apple")
        #expect(IOSContextProvider.osName == "iOS")
        #if targetEnvironment(simulator)
            #expect(IOSContextProvider.isSimulator)
        #else
            #expect(!IOSContextProvider.isSimulator)
        #endif
    }

    @Test("before the first refresh only the timezone is given, marked pending")
    func pendingBeforeRefresh() {
        let provider = provider()

        let values = provider.callTimeValues(disabled: [])

        #expect(values.pending)
        #expect(values.timezone == TimeZone.current.identifier)
        #expect(values.locale == nil)
        #expect(values.networkType == nil)
    }

    @Test("after the refresh the call-time values carry the locale, the timezone and the monitor's type")
    func afterRefresh() {
        let monitor = PathNetworkMonitor()
        monitor.apply(.init(connected: true, networkType: "wifi"))
        let provider = IOSContextProvider(bundle: .main, network: monitor)
        provider.refresh(disabled: [])

        let values = provider.callTimeValues(disabled: [])

        #expect(!values.pending)
        #expect(values.networkType == "wifi")
        #expect(values.timezone == TimeZone.current.identifier)
        #expect(values.locale == IOSContextProvider.currentLocale())
        monitor.apply(.init(connected: false, networkType: nil))
        #expect(provider.callTimeValues(disabled: []).networkType == nil)
    }

    @Test("a disabled field is left out and never read")
    func disabledFields() {
        let provider = provider()
        provider.setMainThreadValues(
            .init(osVersion: "17.5.1", deviceType: "phone", screenWidth: 1179, screenHeight: 2556, screenDensity: 3))
        provider.refresh(disabled: [])

        let values = provider.staticValues(disabled: [.deviceModel, .screenWidth, .appNamespace])
        let callTime = provider.callTimeValues(disabled: [.locale, .networkType, .timezone])

        #expect(values.deviceModel == nil)
        #expect(values.screenWidth == nil)
        #expect(values.appNamespace == nil)
        #expect(values.screenHeight == 2556)
        #expect(values.deviceManufacturer == "Apple")
        #expect(values.osVersion == "17.5.1")
        #expect(callTime.locale == nil && callTime.networkType == nil && callTime.timezone == nil)
        #expect(!callTime.pending)
    }

    @Test("the main-thread values are read by attach and every field has the right type")
    @MainActor
    func attachReadsUIKitValues() async {
        let provider = provider()
        provider.attach()

        let values = provider.staticValues(disabled: [])

        #expect(values.appNamespace?.isEmpty == false || values.appNamespace == nil)
        #expect(values.deviceManufacturer == "Apple")
        #expect(values.deviceModel?.isEmpty == false)
        #expect(values.osName == "iOS")
        #if canImport(UIKit)
            #expect(values.osVersion?.isEmpty == false)
            #expect(["phone", "tablet", "tv"].contains(values.deviceType ?? ""))
            #expect((values.screenWidth ?? 0) > 0)
            #expect((values.screenHeight ?? 0) >= (values.screenWidth ?? 0))
            #expect((values.screenDensity ?? 0) >= 1)
        #else
            #expect(values.osVersion == nil)
            #expect(values.screenWidth == nil)
        #endif
    }

    @Test("attach off the main thread posts the read there")
    func attachOffMain() async {
        let provider = provider()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                provider.attach()
                continuation.resume()
            }
        }
        await MainActor.run {}

        #if canImport(UIKit)
            #expect(provider.staticValues(disabled: []).osVersion != nil)
        #endif
    }
}
