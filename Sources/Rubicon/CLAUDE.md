# Rubicon

The iOS side: the factory, the `Platform` implementations, lifecycle, screens, deep links, context
collection, the network monitor, the HTTP transport's `URLSession`, `RubiconNetworkObserver`, the
`os.Logger` sink and the privacy manifest. Public API at the top level, implementations under
`Platform/`, `Lifecycle/` and `Network/`. UIKit imports sit inside `#if canImport(UIKit)` so
`swift build` on macOS compiles. Pointers such as (iOS Lifecycle 3) name the Confluence decision.

## Factory and process

- `public enum RubiconAnalytics` is a caseless namespace; `static func make(configuration:) -> any
  Analytics` is the only way in; it also holds the version string and, as `package`, the instance
  reset for tests (iOS Public API 4). Documented as called on the main thread during launch.
- App extensions (iOS Queue 2): when `Bundle.main.bundlePath` ends in `.appex` the factory returns the
  no-op instance with one INFO line; `UIApplication.shared` is never touched there.
- Nothing is read from disk on the main thread in the factory. Files live under
  `Application Support/rubicon/` with `isExcludedFromBackup`, never in `UserDefaults`, the Keychain
  or a backed-up directory; `identifierForVendor` is never read (iOS Identity 1).
- Required-reason APIs (iOS Privacy 1) are called only under `Platform/` and only for the two
  declared categories: `ProcessInfo.systemUptime` (`35F9.1`) and the two creation dates of install
  detection (`C617.1`); the stores read no file metadata at all. `check-required-reason-apis.sh` enforces
  the location; `PrivacyInfo.xcprivacy` and the iOS Privacy page change before a third category
  appears.

## Lifecycle and automatic events

- Automatic events have plain Title Case names and `source == .auto`; developer calls are `.app`.
  Inventory (Lifecycle 1): `Application Installed`, `Application Updated`, `Application Opened`
  (`from_background`), `Application Backgrounded`, `Session Started`, `Session Ended`, automatic
  `ScreenEvent`, `Deep Link Opened`, `Network Request`. No element interaction, no crash events.
- `Autocapture` defaults (Lifecycle 6): `appLifecycle`, `installUpdate`, `sessions`, `screenViews`,
  `networkRequests` on; `deepLinks` off.
- The core's lifecycle logic makes these events on the writer; this target only reports the
  foreground and background and the bundle facts. `LifecycleSource` observes
  `UIApplication.willEnterForegroundNotification` and `didEnterBackgroundNotification`, never the
  `active` pair. At startup `applicationState` is read on the main thread (`.active` or `.inactive`
  -> foreground at once; `.background` -> wait); off the main thread the app is assumed to be in the
  background until a notification arrives (iOS Session 1).
- Backgrounding (iOS Queue 2): `beginBackgroundTask(withName: "rubicon.flush")` around the background
  flush, ended when the uploader is idle or on the first failure with the writer idle, on
  `willEnterForeground`, or by the expiration handler, which cancels the in-flight task (the batch
  stays on disk, `cancelled`). Foreground uploads are not wrapped. `willTerminateNotification`
  asks the writer to persist the stores and waits at most one second; no upload.
- Protected data (iOS Disk 1): `isProtectedDataAvailable` read on the main thread at startup;
  `protectedDataWillBecomeUnavailableNotification` and `DidBecomeAvailable` forwarded to the writer.
  The startup flag is advisory: the writer tries to load and a permission error decides, since the
  simulator's test host reports the flag false and never posts the notification (log row 7.1).
- Install and update (iOS Lifecycle 4): on the first foreground, with the version record in
  `DeviceStore`. No record: `installTime` = creation date of the `Library` directory, `updateTime` =
  creation date of `Bundle.main.bundleURL`; within 60 s of each other -> `Application Installed`,
  else `Application Updated` without `previous_version`; if either date cannot be read, no record
  and no event, try again next time. With a record, the Android rules (`is_downgrade` only when
  lower). `installed_at` and `updated_at` are ISO strings. Reads happen on the worker. The bundle
  date under `C617.1` is marked for confirmation with Apple; the fallback (the `Library` date against
  now with a 24 h threshold, no `updated_at`) is a switch in the code, not a rewrite.

## Screens and deep links

- Swizzling policy (iOS Lifecycle 1): exactly one method, `UIViewController.viewDidAppear(_:)`,
  only when `screenViews` is enabled, once per process, on the main thread when `LifecycleSource`
  starts, `class_addMethod` then `class_replaceMethod` with `method_exchangeImplementations` as the
  fallback, never reversed; a failed installation is one WARN. Nothing else is ever swizzled.
- Screen names (iOS Lifecycle 2): `(type(of: controller) as? ScreenNamed.Type)?.screenName`
  (`name_source: "annotation"`), else the class name without a module prefix and without
  `ViewController` (`name_source: "class"`); never the title. Skip classes from outside the main
  bundle, `UIHostingController` and its subclasses, container controllers; resolve the visible
  controller through presented, `visibleViewController`, `selectedViewController`, first child. The
  same instance twice in a row is skipped; A to B to A counts. On `willEnterForeground` the last
  captured screen is sent again if its controller is still visible. No SwiftUI modifier.
- Deep links (iOS Lifecycle 3, Privacy 5b): `trackDeepLink(_ url:referrer:)` and `trackDeepLink(_
  activity:)` (only `NSUserActivityTypeBrowsingWeb` with a `webpageURL`, else a DEBUG line). Properties
  `scheme`, `host`, `path`, the `utm_*` present, `referrer` (a bundle identifier, or the referrer
  URL's host); never other parameters, the fragment or a combined `url`. Ignored with a DEBUG line
  when `deepLinks` is absent or switched off remotely. No deduplication of deliveries.

## Context collection

- `ContextProvider` is implemented here; the core's pipeline adds the values. Nothing touches the
  disk in the factory; the bundle values and the `uname` model are read once on the worker, and
  the UIKit values (OS version, idiom, `nativeBounds`), main-actor isolated in Swift 6, once on the
  main thread by `attach()` at creation: memory reads only (Context 1, log row 7.3).
- Sources (iOS Context 1): `app.name` `CFBundleName` else `CFBundleDisplayName`; `app.version`
  `CFBundleShortVersionString`; `app.build` `CFBundleVersion`; `app.namespace` `bundleIdentifier`;
  `device.manufacturer` `"Apple"`; `device.model` `utsname.machine`; `device.type` from
  `userInterfaceIdiom` (`phone`, `tablet`, `tv`, else omitted); `device.is_emulator` `#if
  targetEnvironment(simulator)`; `os.name` `"iOS"`; `os.version` `UIDevice.current.systemVersion`;
  `screen.width|height` `UIScreen.main.nativeBounds` in pixels, short side first; `screen.density`
  `UIScreen.main.scale`; `network.type` from the shared path monitor (`wifi`, `cellular`,
  `ethernet`, else omitted); `locale` `Bundle.main.preferredLocalizations.first` + `-` + the region
  when present; `timezone` `TimeZone.current.identifier`; `library` `rubicon-ios` and the version.
  `os.api_level` and `network.carrier` do not exist on iOS; `ContextField` has sixteen cases.
- Refresh (iOS Context 2): `app`, `device`, `os`, `library`, `screen` static; `network.type` cached
  by the `pathUpdateHandler`; `timezone` and `locale` read per event on the calling thread. No
  observers of the SDK's own for screen, locale or time zone. The `pending` path of log row 7.3
  applies before the cache is filled. A disabled field is never read.
- Never collected: location, advertising ids, IP, battery, memory, storage, orientation,
  bluetooth, carrier, user agent.

## Network monitor

- One `NWPathMonitor` per instance on its own serial queue, started with the instance, never
  cancelled; its handler must not block: it updates the context cache, wakes the uploader and ends
  network waits. Connected = `.satisfied` or `.requiresConnection`; optimistic until the first
  update; `isExpensive` and `isConstrained` unused. No permission exists, so
  `NETWORK_STATE_PERMISSION_MISSING` is Android-only (iOS Retry 1).

## HTTP and TLS

- The `URLSession` configuration, the delegate that refuses redirects, the zlib call, the `URLError`
  table and the User-Agent are in `Sources/RubiconCore/CLAUDE.md`; this target supplies the
  `ProcessInfo.operatingSystemVersion` string and the blocked-host resolver.
- TLS, pinning and proxies are the platform's: ATS, `NSPinnedDomains`, the device trust store,
  system proxies. The delegate never handles authentication challenges. An `http` host fails with
  `TLS_FAILED` unless the app declares an ATS exception; `CLEARTEXT_HOST` says so (iOS HTTP 4).

## HTTP call capture

- `RubiconNetworkObserver(analytics:hosts:maskPathIds:)` (iOS Lifecycle 5), `final class ...:
  Sendable`, with `urlSession(_:task:didFinishCollecting:)` and `urlSession(_:task:didCompleteWithError:)`
  that the app forwards from its own delegate (or Alamofire's `EventMonitor`). Metrics are kept per
  task behind a weak key; the event is produced on completion.
- It **never** modifies a request, **never** throws, **never** captures the SDK's own session.
  Opted out, `networkRequests` off (checked per call, remote switch-off included) or a non-SDK
  `Analytics`: return at once.
- `Network Request` properties: `method`, `url` without query or fragment, `host`, `path`,
  `status_code`, `error` (`canceled`, `timeout`, `unknown_host`, `connect`, `tls`, else
  `url_error_<code>`; never a message), `duration_ms` from `taskInterval`, `request_bytes`,
  `response_bytes`. Headers and bodies are never captured. Path segments that are all digits, a UUID
  or hex longer than 16 characters become `:id` (`maskPathIds`, default `true`). Hosts: an exact
  name or `*.domain.tld`; nothing is captured for an unconfigured host.

## Logging sink

- `logging.logger = nil` -> `os.Logger(subsystem: "com.rubicon.analytics", category: "Rubicon")`,
  the only code in the SDK that may call `os.Logger` or `os_log`. Mapping: `error` -> `.error`,
  `warn` -> `.default` (the notice level), `info` -> `.info`, `debug` -> `.debug`; the message is
  interpolated with `privacy: .public`, which the content rule makes safe (iOS Logging 1); an error
  is named by domain and code, never its description. Logging is never compiled out of release
  builds.

## Privacy manifest

- `Sources/Rubicon/PrivacyInfo.xcprivacy`, declared with `.process`, is the one manifest (iOS
  Privacy 1): `NSPrivacyTracking` false, no tracking domains; collected types Device ID, User ID,
  Product Interaction, Performance Data and Coarse Location (linked, not tracking, Analytics) and
  Other Diagnostic Data (not linked, App Functionality); accessed APIs `SystemBootTime` `35F9.1` and
  `FileTimestamp` `C617.1`. A test on the simulator reads the bundled manifest and asserts this
  content. Any new data type or API category changes the manifest, the iOS Privacy page and the
  integration guide's label table first.

## Tests

- Swift Testing on the simulator (`Scripts/test-simulator.sh`); `swift test` on macOS only proves
  the target builds. Notifications are posted through `NotificationCenter` in tests; a `UIWindow`
  with real controllers exercises the swizzle; the real `NWPathMonitor` is started once and must
  deliver a path. Nothing here sleeps; waits use `confirmation` with a deadline.
- Every code path that reads UIKit state does so on the main thread, and the tests assert it with
  `dispatchPrecondition` in debug.
