import Testing

@testable import RubiconCore

/// Lifecycle 3 and iOS Lifecycle 2: the class-derived screen name.
@Suite("ScreenNames")
struct ScreenNamesTests {
    @Test("the module prefix and the ViewController suffix are removed")
    func classNames() {
        #expect(ScreenNames.name(forClass: "MyApp.SettingsViewController") == "Settings")
        #expect(ScreenNames.name(forClass: "CheckoutViewController") == "Checkout")
        #expect(ScreenNames.name(forClass: "MyApp.Checkout") == "Checkout")
        #expect(ScreenNames.name(forClass: "ViewController") == "ViewController")
        #expect(ScreenNames.name(forClass: "Shop.Flows.PaymentFlowViewController") == "PaymentFlow")
    }

    @Test("the name sources are the Android wire values")
    func sources() {
        #expect(ScreenNames.nameSource == "name_source")
        #expect(ScreenNames.declared == "annotation")
        #expect(ScreenNames.fromClass == "class")
    }
}
