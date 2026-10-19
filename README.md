# Rubicon iOS SDK

The Rubicon analytics SDK for iOS: a Swift package that records what happens in your app, stores
it on the device and uploads it in batches to your Rubicon backend, with an Objective-C wrapper for
apps written in Objective-C. It implements the same contract as the Android SDK, so one backend
serves both.

- iOS 15 and later, Xcode 16 and later, Swift 5 and Swift 6 language modes.
- One dependency: none. Foundation, UIKit, Network and the system `zlib` only.
- Swift Package Manager only. No CocoaPods, no binary.

## Installation

Xcode: File, Add Package Dependencies, enter `https://github.com/rubicon-team/rubicon-ios-sdk`,
and add the `Rubicon` product to your app target. Objective-C apps add `RubiconObjC` as well.

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/rubicon-team/rubicon-ios-sdk", from: "0.1.0")
],
targets: [
    .target(name: "YourApp", dependencies: [.product(name: "Rubicon", package: "rubicon-ios-sdk")])
]
```

## Quick start

Create one instance during launch, on the main thread, and keep it for the life of the process.
A second call returns the first instance (and is a developer error in a debug build).

```swift
import Rubicon

var config = AnalyticsConfiguration(apiKey: "rk_live_...")
config.host = "https://analytics.example.com"  // your Rubicon backend; the default is the SaaS host
let analytics = RubiconAnalytics.make(configuration: config)

analytics.track("Purchase Completed", properties: ["amount": 49.90, "currency": "USD"])
analytics.screen("Checkout")
analytics.identify("user-42", traits: ["plan": "pro"])
```

Apps built with the iOS 27 SDK must adopt the scene lifecycle; create the instance in
`application(_:didFinishLaunchingWithOptions:)` and build your window in the scene delegate. The
SDK listens to the application notifications, which fire under both lifecycles.

Every method returns at once and may be called from any thread. Properties and traits are checked
on the calling thread: a value the SDK cannot send (a struct, `Data`, a closure) drops only its own
key with a warning in the log; everything else is sent (see "Values" below).

### Firebase in the same app

Firebase also exports a type named `Analytics`. If your file imports both, write the protocol's
name with its module:

```swift
let analytics: Rubicon.Analytics = RubiconAnalytics.make(configuration: config)
```

## What the SDK sends

Three event kinds, `track`, `screen` and `identify`, each with a UUIDv7 message id, a timestamp,
the device id, the user id when identified, your properties and a `context` object (app version,
device model, OS, screen, network type, locale, timezone, session, library). The exact JSON is in
`docs/wire-format.md`.

Automatic events, each switchable:

| `Autocapture` case | Events | Default |
| --- | --- | --- |
| `.appLifecycle` | `Application Opened`, `Application Backgrounded` | on |
| `.installUpdate` | `Application Installed`, `Application Updated` | on |
| `.sessions` | `Session Started`, `Session Ended`, the `session` context | on |
| `.screenViews` | A `screen` event when a view controller appears | on |
| `.deepLinks` | `Deep Link Opened` for the links you pass to `trackDeepLink` | off |
| `.networkRequests` | `Network Request` for the hosts you give `RubiconNetworkObserver` | on |

```swift
config.autocapture.enabled.remove(.screenViews)
config.autocapture.enabled.insert(.deepLinks)
```

### Screen names

Automatic screen views are named after the view controller's class without the module prefix and
the `ViewController` suffix: `CheckoutViewController` becomes `Checkout`. To choose the name,
adopt `ScreenNamed`:

```swift
final class PaymentFlowViewController: UIViewController, ScreenNamed {
    static let screenName = "checkout"
}
```

SwiftUI hosting controllers and UIKit's own controllers never produce a screen; call `screen(_:)`
from your SwiftUI views where you want one.

### Deep links

Forward the links you receive; the SDK keeps the scheme, host, path, the `utm_*` parameters and
the referrer, never other query parameters or the fragment.

```swift
// URL scheme, from the scene delegate's openURLContexts
analytics.trackDeepLink(context.url, referrer: context.options.sourceApplication)
// Universal link
analytics.trackDeepLink(userActivity)
```

### Network requests

The SDK never swizzles `URLSession`. To record requests to your own hosts, forward two delegate
methods of a `URLSession` you own to a `RubiconNetworkObserver`; `URLSession.shared` has no
delegate and therefore cannot be captured.

```swift
final class SessionDelegate: NSObject, URLSessionTaskDelegate {
    let observer = RubiconNetworkObserver(analytics: analytics, hosts: ["api.example.com", "*.cdn.example.com"])

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        observer.urlSession(session, task: task, didFinishCollecting: metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        observer.urlSession(session, task: task, didCompleteWithError: error)
    }
}
```

The event carries the method, the URL without query or fragment and with numeric and UUID path
segments replaced by `:id`, the status code or an error name, the duration and the byte counts.
Never headers, never bodies. The SDK's own host is never captured.

## Configuration

`AnalyticsConfiguration` is a value: set what you need, pass it to `make`, and later changes to
your copy do not reach the SDK. Only `apiKey` is required.

| Setting | Default | Meaning |
| --- | --- | --- |
| `host` | the SaaS host | Base URL of your backend, `https://` (or `http://` with an ATS exception, below) |
| `debug` | `true` in a Debug build | Developer mistakes trap instead of being logged; set it from your own flag to override |
| `beforeSend` | `[]` | Hooks, below |
| `flush.at`, `flush.intervalMs` | 30, 60 000 | An upload starts after this many pending events, or this long after the first |
| `flush.immediateEvents` | `[]` | Event names that upload right away |
| `session.backgroundTimeoutMs` | 300 000 | Time in the background after which the session ends |
| `autocapture.enabled` | all but `.deepLinks` | The table above |
| `context.disabledFields` | `[]` | `ContextField` values never read, such as `.locale` |
| `privacy.defaultConsent`, `privacy.persistConsent` | `.granted`, `true` | Consent, below |
| `logging.level`, `logging.logger`, `logging.eventObserver`, `logging.sendDiagnostics` | `.warn`, system log, `nil`, `true` | Logging, below |
| `network.headers` | `[:]` | Headers added to every request, for gateways |

Numbers out of range are clamped with a warning. A blank API key or an invalid host gives a no-op
instance in a release build (`isOptedOut` is `true`, `deviceId` is empty) and traps in debug.

Your backend can restrict the configuration remotely (switch off automatic events, lower limits,
stop collection); see `docs/remote-config.md`.

### Hooks

A `beforeSend` closure sees every event before it is stored, on the thread that called the SDK.
Return the event, changed or not, or `nil` to drop it. Events are values: copy, change, return.

```swift
config.beforeSend = [
    { event in
        guard var track = event as? TrackEvent else { return event }
        if track.name.hasPrefix("debug_") { return nil }
        track.properties["tenant"] = .string("acme")
        return track
    }
]
```

Automatic events can be changed but not dropped or renamed; a hook that tries is ignored with a
`HOOK_VIOLATION` log. A hook that traps stops the app, as any Swift closure would; keep hooks
simple and never block.

### Values

Properties and traits take `[String: Any]`. Strings, booleans, numbers (`Int`, `Double`, `Float`,
`Decimal`, `NSNumber`), `Date` (sent as ISO 8601 in UTC), `URL` (its string), `NSNull`, arrays and
nested dictionaries up to three levels are sent; anything else drops its key with a warning.
Booleans and numbers are never confused: `true` and `1` stay apart however the value was created.
Limits: 255-character names and keys, 1024-character strings (truncated), 256 properties, 32 KB per
event.

**Enums.** A plain enum case is sent as its case name. An enum that is `CustomStringConvertible`
sends its description, an `@objc` enum sends its integer, and an enum with associated values is
dropped. For stable names pass `rawValue` yourself: `["plan": plan.rawValue]`.

## Consent

The SDK collects from the first call unless you say otherwise. Two methods and one setting:

```swift
analytics.optOut()      // stops collecting; new events are dropped, stored events still upload
analytics.optIn()       // resumes
analytics.isOptedOut    // true while opted out or while consent is pending
```

For a consent platform (CMP) or a region where consent comes first, start pending and opt in
when the user agrees. The SDK stores the choice on the device (`persistConsent`), so the question
is asked once; set `persistConsent = false` to keep the choice in your own storage and call
`optIn` or `optOut` at every launch.

```swift
config.privacy.defaultConsent = .pending
let analytics = RubiconAnalytics.make(configuration: config)
// later, from your CMP callback
if consentGiven { analytics.optIn() } else { analytics.optOut() }
```

`reset()` returns to an anonymous user and starts a new session. `clearLocalData()` deletes
everything stored about the person, renews the device id and keeps the consent choice.

## Logging and QA

By default the SDK writes warnings and errors to the unified log under the subsystem
`com.rubicon.analytics` (Console.app, filter by subsystem). Each warning or error carries a stable
code from `docs/issue-codes.md`, logged once per process. Messages never contain property values,
ids, keys, headers or bodies. To route the log elsewhere:

```swift
config.logging.level = .info
config.logging.logger = { level, message, error in
    myLogger.log("\(level) \(message) \(error.map { "\($0)" } ?? "")")
}
```

For a QA screen or a test, the event observer tells you what became of each event, on the SDK's
own queues:

```swift
config.logging.eventObserver = { update in
    switch update {
    case .queued(let event): print("stored", event.messageId)
    case .sent(let ids): print("sent", ids.count)
    case .dropped(let ids, let reason): print("dropped", ids.count, reason)
    @unknown default: break
    }
}
```

`SDK Diagnostics`, an hourly event with drop and issue counts and no identity, keeps the backend
informed of problems; `logging.sendDiagnostics = false` turns it off.

## On-premise and proxies

- **Cleartext hosts.** `http://` works only with an App Transport Security exception in your
  `Info.plist`; without it the first upload fails with `TLS_FAILED`:

  ```xml
  <key>NSAppTransportSecurity</key>
  <dict>
      <key>NSExceptionDomains</key>
      <dict>
          <key>analytics.internal.example</key>
          <dict>
              <key>NSExceptionAllowsInsecureHTTPLoads</key><true/>
              <key>NSIncludesSubdomains</key><true/>
          </dict>
      </dict>
  </dict>
  ```

- **Custom certificate authority.** The SDK uses the system trust store: install the CA on the
  device (an MDM profile or a configuration profile) and `https://` works without any SDK setting.
- **Certificate pinning.** Declare `NSPinnedDomains` for your analytics host in `Info.plist`;
  the SDK's `URLSession` honours it. The SDK adds no pinning API of its own.
- **Proxies.** System HTTP proxies, PAC files and VPNs apply automatically. Gateways that need a
  header get it from `network.headers`; `Authorization`, `User-Agent`, `Content-Type` and
  `Content-Encoding` are reserved.
- The requests are `POST {host}/v1/batch` (gzip JSON) and `GET {host}/v1/config`, with
  `Authorization: Bearer {apiKey}` and `User-Agent: rubicon-ios/{version} (iOS {os})`. Redirects
  are refused and logged as `HTTP_REDIRECT`; point `host` at the final URL.

## Privacy

The `Rubicon` target ships a privacy manifest (`PrivacyInfo.xcprivacy`): no tracking, the data
types below, and two required-reason APIs (`35F9.1` for the uptime clock, `C617.1` for the two
file dates of install detection). `docs/privacy-manifest.md` explains every entry. For your App
Store privacy label, the SDK's share is:

| SDK feature | Data type on the label | Drop the row when |
| --- | --- | --- |
| Any upload | Device ID | never |
| Any upload | Coarse Location (the backend derives it from the IP address) | the project's IP anonymisation setting is on |
| `identify` | User ID | the app never calls `identify` |
| `track`, `screen`, the automatic events | Product Interaction | never in practice |
| `.networkRequests` | Performance Data | network capture is disabled |
| `sendDiagnostics` | Other Diagnostic Data | `sendDiagnostics` is `false` |

Every type is "linked to you" once the app calls `identify`; none is "used to track you". The SDK
never reads the advertising identifier, never calls App Tracking Transparency, and stores its files
under `Application Support/rubicon`, excluded from backup. Inside an app extension the SDK is a
no-op.

## Objective-C

Add the `RubiconObjC` product. The wrapper mirrors the Swift API with `RBN` prefixes and
Objective-C names; a `beforeSend` block that raises an `NSException` drops the event instead of
crashing the app.

```objc
@import RubiconObjC;

RBNConfiguration *config = [[RBNConfiguration alloc] initWithApiKey:@"rk_live_..."];
config.host = @"https://analytics.example.com";
[config.autocapture disable:RBNAutocaptureNetworkRequests];
[config addBeforeSend:^RBNEvent *(RBNEvent *event) {
    if ([event isKindOfClass:[RBNTrackEvent class]]) {
        RBNTrackEvent *track = (RBNTrackEvent *)event;
        NSMutableDictionary *properties = [track.properties mutableCopy];
        properties[@"tenant"] = @"acme";
        track.properties = properties;
    }
    return event;
}];
RBNAnalytics *analytics = [RBNAnalytics makeWithConfiguration:config];

[analytics trackEvent:@"Purchase Completed" properties:@{@"amount": @49.90}];
[analytics identifyUser:@"user-42" traits:@{@"plan": @"pro"}];
[analytics trackDeepLink:url referrer:sourceApplication];
```

`RBNScreenNamed` is the class method `+rbnScreenName` on a view controller;
`RBNNetworkObserver` takes the same two delegate methods; `RBNEventUpdate` is the observer's
update with a `kind`.

## Behaviour worth knowing

- Events are written to disk before anything else happens to them; a crash or a kill loses at most
  the events that were still in memory on the calling thread's way to the writer.
- Uploads run inside a background task when the app goes to the background; if the system ends the
  task first, the batch stays on disk and goes with the next trigger or the next launch.
- Offline, nothing is sent and nothing is lost; the queue holds 1000 events or three days, oldest
  dropped first, and every drop is counted into `SDK Diagnostics`.
- The same event can reach the backend twice after a lost response; it carries the same message id
  both times.
- Non-integral numbers are written with seventeen significant digits (`49.899999999999999` for
  `49.9`); your backend must parse numbers, not compare their text (`docs/wire-format.md`).

## Repository

| Path | What it is |
| --- | --- |
| `Sources/RubiconCore` | The platform-free core: pipeline, queue, disk format, HTTP, retry, session, identity |
| `Sources/Rubicon` | The iOS target: factory, lifecycle, screen capture, network observer, privacy manifest |
| `Sources/RubiconObjC` | The Objective-C wrapper |
| `ConsumerApps/` | Three apps (Swift 5, Swift 6, Objective-C) that build against the package in CI and run the simulator scenarios |
| `docs/` | `wire-format.md`, `issue-codes.md`, `privacy-manifest.md`, `remote-config.md` |
| `API/` | The recorded public API; a change here is a public API change |

The design is fixed in decision pages kept outside this repository; the Android SDK's decisions
are the contract both platforms implement. Development: `Scripts/check.sh` runs what CI runs;
`Scripts/check.sh --all` adds the simulator suite, the consumer apps and the DocC build.

## License

Apache License 2.0; see `LICENSE`.
