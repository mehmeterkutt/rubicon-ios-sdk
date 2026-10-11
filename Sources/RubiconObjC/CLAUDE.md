# RubiconObjC

The Objective-C wrapper (iOS Public API 1): `NSObject` classes prefixed `RBN` that forward to the
Swift API of `Rubicon`. Objective-C apps add this product next to `Rubicon`; Swift apps never
compile it. Everything here is a view over the Swift types; no logic of its own.

## Shape

- Swift files with `@objc public final class RBN...: NSObject`; `@objc public enum` with `Int` raw
  values for `RBNLogLevel`, `RBNAutocapture`, `RBNContextField`, `RBNConsent`, `RBNDropReason`,
  `RBNEventUpdateKind`, `RBNEventSource`. Names follow Objective-C conventions (`trackEvent:
  properties:`, `identifyUser:traits:`, `trackDeepLink:referrer:`, `trackDeepLinkWithActivity:`);
  the Swift names are decided, the Objective-C selectors are decided in step 7.7 and then fixed.
- `RBNAnalytics` holds the `any Analytics` and exposes every verb, `isOptedOut` and `deviceId`;
  `+[RBNAnalytics makeWithConfiguration:]` is the factory. `RBNConfiguration` is an `NSObject`
  holding an `AnalyticsConfiguration` and exposing every setting as a property; numeric settings
  are plain properties (the Swift settings are non-optional, so no sentinels); the hooks and the
  logger are blocks.
- `RBNTrackEvent`, `RBNScreenEvent`, `RBNIdentifyEvent`: read-only fixed fields, settable `name` and
  `properties` or `traits` as `NSDictionary`, converting to and from the structs through the same
  validator as Swift. `RBNEventUpdate`: `kind`, `event`, `messageIds`, `dropReason`.
  `RBNScreenNamed` is an informal protocol with a class method `screenName`.
- `RBNNetworkObserver` wraps `RubiconNetworkObserver` with the same two delegate-shaped methods.

## Rules

- Forward, never reimplement: validation, hooks, the pipeline and the logger live in `Rubicon` and
  the core. A wrapper method is one call plus the type conversion.
- A `beforeSend` block is boxed in an `NSObject` and called with `NSException` caught; a throwing
  block drops the event with reason `before_send`, as PostHog's `BoxedBeforeSend` does. A logger
  block that throws is replaced by the platform default with `LOGGER_THREW`; an observer block that
  throws is switched off (Logging 4b applies here, not in Swift).
- `NSDictionary` properties go through the Swift validator unchanged; `NSNumber` booleans are told
  apart by the `CFBoolean` rule, so `@YES` and `@1` stay distinct (iOS Public API 5).
- No UIKit import of its own, no `print`, no logic that would need a test of its own beyond
  forwarding and conversion.
- Every public symbol has a documentation comment in the Objective-C reader's terms.

## Tests

- `Tests/RubiconObjCTests`, Objective-C `.m` files with XCTest, run on the simulator
  (`Scripts/test-simulator.sh`). One test per wrapper method, configuration setter, block and
  conversion; the throwing block cases; and the compile itself, which is half the test: a method
  that does not import into Objective-C fails the build (iOS Public API 1, D16).
