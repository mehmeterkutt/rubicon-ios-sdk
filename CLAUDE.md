# Rubicon iOS SDK

Analytics SDK for iOS in Swift. This file and each target's `CLAUDE.md` are the contract for how code
is written here; read them before changing anything.

- The design is fixed in a set of decision pages kept outside this repository and is binding. Each
  iOS page inherits the Android decision page of the same block, and only what differs on iOS is
  written on the iOS page. A pointer such as (Queue 4) means decision 4 on the Android Queue with
  Flush Policy page; (iOS Queue 2) means decision 2 on the iOS page. The reasoning lives there, not
  here.
- Never decide something the decisions do not cover: stop and ask, with options and a recommendation.
- The Android SDK (`~/Projects/rubicon-android-sdk`) is the reference implementation of the same
  contract: port its code, its golden wire files (`Tests/RubiconCoreTests/Fixtures/golden`, copied
  verbatim), `docs/issue-codes.md` and its implementation decisions log, unless an iOS page says
  otherwise. Where Android code and an iOS decision disagree, the iOS decision wins.

## Targets

| Target | Role |
|---|---|
| `RubiconCore` | Foundation only: configuration, pipeline, queue, storage, identity, sessions, HTTP, retry, logging. `swift test` on macOS. Rules: `Sources/RubiconCore/CLAUDE.md` |
| `Rubicon` | iOS: factory, platform implementations, lifecycle, screens, deep links, context, `RubiconNetworkObserver`, the `os.Logger` sink, the privacy manifest; re-exports the core. Simulator tests. Rules: `Sources/Rubicon/CLAUDE.md` |
| `RubiconObjC` | The Objective-C wrapper (`RBN` prefix), a separate product depending on `Rubicon`. Rules: `Sources/RubiconObjC/CLAUDE.md` |
| `RubiconTesting` | Test support for the test targets: `TestPlatform` fakes, the virtual-time scheduler, `TestHTTPServer`. Never a product. |
| `ConsumerApps/*` | Never shipped: a Swift 5 app, a Swift 6 app and an Objective-C app that build against the package in CI (iOS Public API 3). |

Apps add one product, `Rubicon`, which brings `RubiconCore`; Objective-C apps add `RubiconObjC` as
well (iOS Public API 8). UIKit code lives only in `Rubicon`; when the core needs the platform (clock,
files, network, lifecycle, context) it declares a protocol that `Rubicon` implements. The demo app and
its fake backend are a separate repository (`rubicon-team/rubicon-ios-demo`).

## Commands

```bash
Scripts/check.sh              # everything the pull request lane runs: format lint, swift build (macOS and
                              # iOS 15 simulator triple), swift test with coverage gates, source rules,
                              # required-reason grep, public API record, documentation check
Scripts/check.sh --all        # plus the simulator suite, the three consumer apps and the DocC build
Scripts/format.sh             # swift format in place; before every commit
swift test --filter QueueTests
Scripts/test-simulator.sh [15]   # RubiconTests and RubiconObjCTests on the newest (or iOS 15) simulator
Scripts/build-consumer-apps.sh   # XcodeGen + xcodebuild for Swift5App, Swift6App, ObjCApp
Scripts/api-diff.sh --update  # after a public API change; commit API/*.txt
Scripts/refresh-golden.sh     # copy the Android golden files again (ANDROID_SDK_DIR overrides the path)
swift test --sanitize=thread  # Thread Sanitizer on the core tests (the Nightly workflow, run by hand)
RUBICON_STRESS=1 swift test --filter CoreIntegrationTests/stress   # the stress suite; the Nightly workflow, not per pull request
```

Local toolchain is Xcode 27 (Swift 6.4); the release toolchain is Xcode 26.6 on the `macos-26`
runner, the last that builds for the iOS 15 floor. CI is the gate: a build that passes locally and
fails there is fixed, not waved through. Keep the sources inside `swift-tools-version` 6.0.
The simulator lane costs about twenty macOS minutes a run; while a pull request iterates on what the
macOS lane shows by itself, the label `skip-simulator` skips it. The label comes off before the merge.

## Non-negotiables

A pull request that breaks one does not merge.

1. **Never crash the host app.** No force unwrap, `try!`, `fatalError` or `precondition` in SDK code;
   every public entry point and every queue closure handles its errors, logs and degrades: the SDK
   failing is an analytics gap, not an app crash. The only traps on purpose go through the internal
   `developerError(_:)`, which calls `assertionFailure` when `configuration.debug` is on (invalid
   configuration, unsupported property type, hook violation, second instance); with `debug` off they
   log instead (iOS Configuration 2).
2. **No events lost silently.** An event is written to disk before `track` returns control to the
   pipeline; upload happens later, with retry and backoff. Offline and a locked device are normal
   states, not errors.
3. **Public API is forever.** Nothing public is removed or renamed. Deprecate with
   `@available(*, deprecated, renamed:)` and keep it working for at least one major version.
4. **Everything is `internal` unless it must be public.** Public surface: the factory, the `Analytics`
   protocol, the configuration, the event types and the hook types. Cross-target use inside the
   package is `package`, never `public` (D-log 2026-10-11).
5. **Application scope only.** Never retain a `UIViewController`, `UIView`, `UIWindow` or scene;
   observers that need one use a weak reference. `UIApplication.shared` only in `Rubicon`, only on
   the main thread, never in an app extension.
6. **No dependencies.** `Package.swift` declares none; Apple frameworks (`Foundation`, `zlib`,
   `CryptoKit`, `Network`, `os`, `UIKit`) are not dependencies. Adding a package is a design
   discussion, not a pull request detail.
7. **Every change ships with tests.** No exceptions for small fixes.

## Public API

- The developer creates and holds the instance: `RubiconAnalytics.make(configuration:)` on a caseless
  enum in `Rubicon` returns `any Analytics`, the protocol of the core. No singleton, no global
  accessor; one instance per process, enforced by the factory; the implementation is internal
  (iOS Public API 4).
- Fixed vocabulary, first argument unlabeled: `track(_:properties:)`, `screen(_:properties:)`,
  `identify(_:traits:)`, `reset()`, `register(_:value:)`, `unregister(_:)`, `flush()`, `optOut()`,
  `optIn()`, `clearLocalData()`, read-only `isOptedOut` and `deviceId` properties, no `userId` getter;
  plus the iOS-only `trackDeepLink(_:referrer:)` and `trackDeepLink(_:)` (iOS Public API 7, iOS
  Lifecycle 3). Methods return nothing: no chaining, no event ids. No `async`, no `Task` in the API.
- Properties are `[String: Any]` at the door, defaulting to `[:]`, validated in one pass on the
  calling thread into `[String: PropertyValue]`, a `Sendable` enum (`string`, `int(Int64)`, `double`,
  `bool`, `null`, `array`, `object`); the caller's dictionary is never kept. Validated again after
  the `beforeSend` chain (iOS Public API 5).
- A boolean is told from a number before any other check with `CFGetTypeID(value as CFTypeRef) ==
  CFBooleanGetTypeID()`; the Swift cast chain misreads `NSNumber` (iOS Public API 5).
- Conversion table (iOS Serialization 2): `NSNull` and empty optionals are `null`; integers of any
  width become `Int64` (`UInt64` above `Int64.max` rejected); `Double` and `CGFloat` as is (NaN and
  infinity rejected); `Float` and `Decimal` through their decimal text; `Character` as a string;
  `Date` as `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'`; `URL` as `absoluteString`; a payload-free enum as its
  case name; arrays and sets as lists (a bad element drops only itself); string-keyed dictionaries
  as objects. Everything else is rejected: drop the key, WARN with key and type only, never the
  value; keep the event; `developerError` in debug.
- Limits (Serialization 3): event line 32 KB (drop, `oversize`); event or screen name and key 1 to
  255 characters (drop, never trim); string values 1024 characters (truncate on a character
  boundary, no marker, WARN); 256 properties with super properties (those dropped first); nesting
  depth 3.
- `AnalyticsConfiguration.beforeSend: [BeforeSend]` with `typealias BeforeSend = @Sendable (any Event)
  -> (any Event)?`, fixed at creation, runs on the calling thread. `nil` drops. A result is accepted
  only if it is a `TrackEvent`, `ScreenEvent` or `IdentifyEvent` of the input's kind with the
  input's fixed fields; `source == .app`: any name and data; `source == .auto`: same name, same
  top-level keys, values free, no `nil`. A breach drops (`before_send`, `HOOK_VIOLATION`),
  `developerError` in debug. `SDK Diagnostics` never reaches hooks (iOS Public API 6, Event Model 1).
- `Event` is a `Sendable` protocol with three structs; fixed fields are `let`, `name` and
  `properties` or `traits` are `var`; initializers are internal. Third-party conformances are
  harmless because the pipeline checks the kind (iOS Event Model 1).
- `AnalyticsConfiguration` is a `Sendable` struct: `let apiKey`, `var` settings with defaults, nested
  structs per group; the factory keeps its copy as the snapshot, nothing is frozen. Never add
  initializer parameters; optional settings only for the hooks and the logger (iOS Configuration 1).
- Public types are `Sendable`; protocols evolve by adding requirements with default implementations
  in an extension; enums that may grow are not `@frozen` and their documentation asks for `default`.
- Documentation comment on every public symbol (`check-docs.sh`), with a short example when it
  prevents misuse.
- The public API record is `API/<module>.txt`, written by `Scripts/api-diff.sh --update` from the
  symbol graph; a diff there is the definition of a public API change and is named at the top of
  the pull request. `diagnose-api-breaking-changes` runs against the last release tag.

## Dependencies

- None at runtime (iOS Public API 8). Frameworks by target: the core imports `Foundation`, `zlib`
  and `CryptoKit` only; `Rubicon` adds `UIKit` (guarded with `#if canImport(UIKit)`), `Network` and
  `os`; `RubiconObjC` imports `Rubicon` and `Foundation`.
- Uploads use the SDK's own `URLSession` behind the internal `HttpTransport`; never
  `URLSession.shared`, never the app's session (iOS HTTP 1).
- No `#available` or `@available(iOS ...)` checks: every API used exists on iOS 15 (iOS Public API 2).
  The test targets too: the local Xcode 27 builds for iOS 17 and up and does not report an iOS 16
  API (the Swift Testing trait `.timeLimit`, `Duration`, `OSAllocatedUnfairLock`); only the Xcode
  26.6 build in CI does.
  No `swift-docc-plugin`, no SwiftLint: tools come from the toolchain or Homebrew on the runner.
- Test-only and tool-only additions are allowed but named in the pull request (so far: XcodeGen).

## Threading

- Every public method is thread-safe and non-blocking. The calling thread only copies arguments,
  validates properties and snapshots identity and super properties; disk and network work is
  enqueued. Calls from the same thread take effect in call order (Public API 9).
- Two serial `DispatchQueue`s, writer and uploader, own all state below the public surface; each
  worker is `final class ...: @unchecked Sendable` with a comment on the line above naming the queue
  that guards it and `dispatchPrecondition(condition: .onQueue(queue))` in debug (iOS Queue 1).
- Other shared state is behind an `NSLock` (`OSAllocatedUnfairLock` needs iOS 16), never `objc_sync`
  on `self`.
  Closures handed to a queue are `@Sendable`. No `DispatchQueue.main` in the core; `Rubicon` touches
  the main queue only for UIKit (source rules).
- Events and configurations are value types, so boundaries need no deep copies; a reference type
  that crosses a queue is `Sendable` or copied first.

## Testing

- Layers, tools and the rules for every test: section 5 of the plan.
- Swift Testing everywhere (`@Suite`, `@Test("sentence")`, `#expect`, `#require`, parameterized
  tests); XCTest only in the Objective-C test target and the consumer apps' UI tests. Fakes come
  from `RubiconTesting`, never a mocking library.
- The core runs on macOS with `swift test` in seconds; `Rubicon` tests run on the simulator through
  `Scripts/test-simulator.sh`; the consumer apps and the demo app cover what the simulator cannot.
- No `sleep` and no real waiting in unit tests: time is virtual through the injected `Scheduler`.
  Every file test uses its own temporary directory; suites run in parallel, nothing is global.
- `TestHTTPServer` (POSIX sockets, D15 revised: `NWListener` failed to listen and to accept on the
  CI simulator) answers in script order across all connections; a test that scripts answers for
  more than one connection binds them to paths with `respond(to:with:)`.
- A suite that holds a real socket or a real queue is nested under its target's serialized parent
  (`RealWorldSuites` in the core tests, `ProcessWideSuites` in the Rubicon tests). A suite that
  creates the process-wide instance also holds `InstanceLease` in its fixture, first stored property,
  one fixture per test: `swift test` runs both test targets in one process, and a fixture's
  `resetForTests` stops whatever instance the slot holds, including another target's.
- Coverage gates (`check-coverage.sh`): 90 percent of lines in `RubiconCore`, 80 percent in `Rubicon`.
- Anything touching upload, storage or identity gets one manual run in the demo app against its fake
  server, once the demo app uses the SDK (step 9.2).

## Code style

- `swift format` with the repository configuration (`Scripts/format.sh`): 4 spaces, 120 columns,
  grouped imports. Readability over cleverness: small functions, one responsibility.
- `struct` for public value types, `protocol` for abstractions, `enum` for fixed sets and for
  namespaces; `final class` only where identity or a lock is the point. No `open` classes.
- Constants are `static let` on the type that owns them or `private let` at file scope.
- Log only through the internal logger (`log.debug { }`, `log.warn(.code) { }`,
  `log.error(.code, error) { }`), never `print`, `debugPrint`, `NSLog` or `os_log` outside the one
  sink in `Rubicon` (iOS Logging 1; source rule `no-print`).
- Never log property or trait values, `userId`, `deviceId`, the session id, the API key, header
  values, bodies or query strings, at any level; names, keys, types, counts, codes and `message_id`
  are fine (Logging 4). On iOS the message is logged `privacy: .public`, so this rule is what keeps
  device logs clean; the source rule rejects those identifiers inside a log call.
- Documents and code comments are in English, without emoji.

## Git and pull requests

- `master` holds releases, `develop` the next one. One plan phase is one `feature/<topic>` branch
  from `develop` and one pull request (phases 2 to 5 share `feature/core-foundations`); each step
  is one commit. Conventional Commits (`feat(queue): ...`, `build: ...`). Squash merge into `develop`.
- Before committing: `Scripts/format.sh`, then `Scripts/check.sh` green.
- On `feature/core-foundations` a finished step is committed at once; on every later branch, stop
  for review with the changes uncommitted. Push and open the pull request only after the user
  approves. Never merge, never push to `develop` or `master`.
- The description follows `.github/pull_request_template.md`.

## Keeping these files honest

They are loaded into every AI session and read by every contributor. When a rule stops matching the
code, fix one or the other in the same pull request. State each rule once; target detail goes into
the target's `CLAUDE.md`. Each file stays under 200 lines, `Sources/RubiconCore/CLAUDE.md` under 250;
this one near 200.
