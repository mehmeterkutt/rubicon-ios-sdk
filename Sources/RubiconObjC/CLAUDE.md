# RubiconObjC

The Objective-C wrapper (iOS Public API 1): `NSObject` classes prefixed `RBN` that forward to the
Swift API of `Rubicon`. Objective-C apps add this product next to `Rubicon`; Swift apps never
compile it. Everything here is a view over the Swift types; no logic of its own.

## Shape

- Swift files with `@objc(RBN...) public final class RBN...: NSObject`; `@objc public enum` with
  `Int` raw values for `RBNLogLevel`, `RBNAutocapture`, `RBNContextField`, `RBNConsent`,
  `RBNDropReason`, `RBNEventUpdateKind`, `RBNEventSource`, each with a `swift` accessor and an
  initializer from the Swift case, so a new Swift case fails to compile here.
- `RBNAnalytics` holds the `any Analytics` and exposes every verb, `isOptedOut` and `deviceId`;
  `+makeWithConfiguration:` is the factory and returns the one view per Swift instance; `+sdkVersion`
  (`version` belongs to `NSObject`). The selectors are fixed in `API/RubiconObjC.txt` and the plan's
  log (7.7): `trackEvent:properties:`, `trackScreen:properties:`, `identifyUser:traits:`,
  `registerSuperProperty:value:`, `unregisterSuperProperty:`, `trackDeepLink:referrer:`,
  `trackDeepLinkWithActivity:`, and the no-argument forms.
- `RBNConfiguration` is `initWithApiKey:` holding a `Locked<AnalyticsConfiguration>`; the groups
  (`flush`, `session`, `autocapture`, `context`, `privacy`, `logging`, `network`) are read-only
  objects that read and write the owner's value. Numeric settings are plain properties (the Swift
  settings are non-optional, so no sentinels); sets are `enable:`/`disable:`/`isEnabled:`; the hooks
  are `addBeforeSend:`, `beforeSendCount`, `removeAllBeforeSend` (an array of blocks does not
  bridge); the logger and the observer are block properties of `logging`.
- `RBNEvent` (read-only fixed fields and `context` as a wire-form `NSDictionary`) with
  `RBNTrackEvent`, `RBNScreenEvent`, `RBNIdentifyEvent`: settable `name` and `properties` or
  `traits` as `NSDictionary`, converting to and from the structs through `PropertyNormalizer`, the
  same validator as Swift. `RBNEventUpdate`: `kind`, `event`, `messageIds`, `dropReason`,
  `dropReasonName`. `RBNScreenNamed` is an `@objc` protocol with the class method `rbnScreenName`,
  found by `ScreenCapture` through `respondsToSelector:`.
- `RBNNetworkObserver` wraps `RubiconNetworkObserver` with the two delegate methods under their
  `NSURLSession` selector names.
- `RubiconObjCSupport` is the one C-family target: `RBNCallReturningObject`, `RBNCallWithObject`,
  `RBNCallLogger`, each a `@try` around a direct call of the developer's block. It is a dependency
  of this target, not a product.

## Rules

- Forward, never reimplement: validation, hooks, the pipeline and the logger live in `Rubicon` and
  the core. A wrapper method is one call plus the type conversion.
- A block is called only through `RubiconObjCSupport`, which receives the block itself and its
  argument. Between the `@try` and the developer's code there may be nothing but the compiler's
  bridging thunk: an `NSException` unwinding through a Swift frame that holds a lock or an
  exclusivity access (`Locked.withLock`, a stored-property write) leaves the access record dangling
  and crashes later, which the first version of this target did. Build the argument before the
  call, read the result after it.
- A `beforeSend` block that raises drops the event with reason `before_send` and logs `HOOK_THREW`
  with the exception's name only. A logger block that raises is replaced by the platform default
  with `LOGGER_THREW`; an observer block that raises is switched off with `OBSERVER_THREW`; both
  stop being called after the first exception even before the instance's log exists (`RBNHookLog`
  carries the pending reports until `make` attaches the log).
- `NSDictionary` properties go through the Swift validator unchanged; `NSNumber` booleans are told
  apart by the `CFBoolean` rule, so `@YES` and `@1` stay distinct (iOS Public API 5).
- No UIKit import of its own, no `print`, no logic that would need a test of its own beyond
  forwarding and conversion.
- Every public symbol has a documentation comment in the Objective-C reader's terms.

## Tests

- `Tests/RubiconObjCTests/RBNTargetTests.m`, Objective-C with XCTest, on macOS (`swift test`) and
  on the simulator (`Scripts/test-simulator.sh`): one real instance through every selector, the
  configuration setters, booleans kept apart, a hook that renames, drops and raises, consent, the
  network observer and `RBNScreenNamed`. Compiling is half the test: a method that does not import
  into Objective-C fails the build (iOS Public API 1, D16).
- `Tests/RubiconTests/RBNWrapperTests.swift` from Swift: enum round trips, the configuration
  mapping, the typed views and their changes on the wire, the observer updates, the three raising
  blocks and every verb against `TestHTTPServer`.
