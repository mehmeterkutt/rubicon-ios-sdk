import Foundation

/// The name of a view controller's automatic screen view (Lifecycle 3, iOS Lifecycle 2), the
/// counterpart of Android's `@ScreenName`. Without it the name is the class name without its module
/// and without `ViewController` (`CheckoutViewController` becomes `Checkout`), sent with
/// `name_source` `"class"`; with it, the declared value, sent with `name_source` `"annotation"`.
///
/// The name is the screen's key on every platform: use the name from your tracking plan, the same
/// on Android, iOS and web, preferably `snake_case`, never displayed text.
///
/// ```swift
/// final class PaymentFlowViewController: UIViewController, ScreenNamed {
///     static let screenName = "checkout"
/// }
/// ```
///
/// A screen is tracked either automatically or with `screen()`, never both: SwiftUI screens are
/// sent with `screen()` from `onAppear`, since `UIHostingController` is never captured; an app that
/// sends every screen itself removes `screenViews` from `autocapture.enabled`.
///
/// The protocol is main-actor isolated, as view controllers are, so a `UIViewController` subclass
/// conforms with a plain `static let` under Swift 6 strict concurrency.
@MainActor
public protocol ScreenNamed {
    /// The screen name, 1 to 255 characters.
    static var screenName: String { get }
}
