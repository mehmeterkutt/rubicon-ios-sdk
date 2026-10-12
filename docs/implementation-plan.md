# Rubicon iOS SDK: Implementation Plan

This plan takes the Rubicon iOS analytics SDK from an empty repository to a release candidate, one
pull request at a time. It is written for an implementing session that starts with a clean context:
it names what to read, what to build, what to test and when a step is done. It does not restate the
design; the design lives in Confluence and is binding. It follows the Android plan
(`~/Projects/rubicon-android-sdk/docs/implementation-plan.md`) step for step where the two SDKs share
a block, so that the two code bases can be read side by side.

## 1. Sources of truth

| Source | What it holds | How to read it |
|---|---|---|
| Confluence, space SD, page "Analytics SDK: iOS" (id `8192025`) and its 14 `iOS: <block>` child pages | What differs on iOS, per block, with reasoning. Binding. Each page opens with what it inherits. | Atlassian MCP, `cloudId` `rubiconn.atlassian.net`, `getConfluencePage` with `contentFormat: "markdown"` |
| Confluence, page "Analytics SDK Design Decisions" (id `3112961`) and its 14 Android child pages | The contract both SDKs implement. Everything an iOS page does not mention is inherited from here unchanged. | Same |
| `~/Projects/rubicon-android-sdk` | The reference implementation of the same contract: `sdk-core/CLAUDE.md` and `sdk-android/CLAUDE.md` (rules as implemented), `sdk-core/src/test/resources/golden/` (the wire contract), `docs/issue-codes.md` (the code catalogue), `docs/remote-config.md`, `docs/wire-format.md`, and section 15 of its plan (platform-neutral rows are part of the contract) | Read-only. Port, do not reinvent; where Android code and an iOS decision disagree, the iOS decision wins. |
| `CLAUDE.md`, `Sources/RubiconCore/CLAUDE.md`, `Sources/Rubicon/CLAUDE.md`, `Sources/RubiconObjC/CLAUDE.md` | The day-to-day rules distilled from the pages, with pointers to the decisions. Written in step 1.2. | Loaded at the start of every session |
| This file | Order of work, tests, done criteria, progress | Read the Status section at the start of every session |
| `~/Projects/analytics-sdk-ios/{posthog-ios, analytics-swift, Amplitude-Swift, snowplow-ios-tracker, mixpanel-swift}` | Source of the five reference iOS SDKs (analytics-swift is Segment) | Read-only, for implementation patterns. Where a reference SDK and a decision disagree, the decision wins. |
| `~/Projects/analytics-sdk/demo-app` (repo `rubicon-team/rubicon-android-demo`) | The fake backend (`fake-server/server.py`), reused by the iOS demo app | Used in phase 9 |

Decision pages (link: `https://rubiconn.atlassian.net/wiki/spaces/SD/pages/<id>`):

| Block | iOS page | Android page | Block | iOS page | Android page |
|---|---|---|---|---|---|
| Public API | 7798805 | 3211265 | Queue with Flush Policy | 9240577 | 4161566 |
| Event Model | 8945665 | 3407873 | Disk Persistence | 9633793 | 4587522 |
| Configuration | 8978442 | 2981890 | Serialization | 9764865 | 4358166 |
| Identity Management | 9043969 | 3833857 | HTTP Client with Compression | 9895937 | 3964956 |
| Context Enrichment | 8880130 | 3899401 | Retry and Network Awareness | 9994241 | 4096005 |
| Session Management | 9175041 | 4161537 | Privacy Controls | 10092545 | 4325427 |
| Automatic Lifecycle Events | 8880160 | 4325379 | Logging | 9601026 | 4554779 |

In this plan "Queue 5" means decision 5 on the Android Queue with Flush Policy page, "iOS Queue 2"
decision 2 on the iOS Queue page, "Disk 2d" decision 2d on the Android Disk Persistence page, and so
on. "Android log 5.1" means the rows of step 5.1 in section 15 of the Android plan.

## 2. Working agreement for the implementing session

1. At the start of a session read `CLAUDE.md`, then section 14 (Status) of this file, and take the
   first unchecked step. Do not work on two steps at once.
2. Phases 2 to 5 (steps 2.1 to 5.3) are one branch, `feature/core-foundations`, and one pull
   request; every step is one commit, made without a review stop, and questions are still asked
   when a decision is missing (decided 2026-10-11, section 15). Steps 6.1 to 8.5 are one branch,
   `feature/sdk-complete`, and one pull request on the same terms: one commit per step, no review
   stop, questions asked when a decision is missing, pushed once at the end (decided 2026-10-12,
   section 15). Step 8.6 (the tag) and phase 9 (the demo repository) come after that pull request.
   A step that turns out too big is split, and the split is written into this file first.
3. Before writing code for a step, read the decisions listed under "Read" in full, iOS page first,
   then the Android page it inherits from, then the Android code named under "Port". Read the
   reference SDK code named there when the step says so.
4. Write the tests listed under "Tests" before or together with the code. A listed test may be
   renamed or merged; it may not be skipped. If a test cannot be written, stop and say why.
5. If a decision is missing, ambiguous, contradicts another decision, or cannot be implemented as
   written (a Foundation limitation, a platform behaviour that differs from the page), stop and ask
   the user, with the options and a recommendation. Never decide silently. Record the answer in
   section 15 and, when it changes a decision, tell the user which Confluence page and which
   `CLAUDE.md` rule need the change; update them after approval. A change to the contract itself is
   a change to the Android page and the backend as well, and is taken only with the user.
6. Done means every item of section 6 (Definition of done) holds. Then tick the step in section 14,
   fill its rows in the traceability table (section 13) and commit (on the core-foundations branch)
   or stop for review with the changes uncommitted (every later branch). Push and open the pull
   request only after the user approves. Never merge, and never push to `develop` or `master`.
7. Documents and code comments are in English, without emoji.

## 3. Open decisions to settle before step 1.1

These are not covered by the Confluence decisions and block the scaffold. Ask the user about each
in one message, with the recommendation, and record the answers in section 15.

| # | Question | Recommendation and reason |
|---|---|---|
| D1 | Repository name, remote, branch model | `rubicon-team/rubicon-ios-sdk`, private; local `~/Projects/rubicon-ios-sdk` (created 2026-10-07). Same branch model as Android: `master`, `develop`, `feature/*`, feature pull requests squash-merged into `develop`. |
| D2 | Package, products, module names, bundle identifiers | Package name `Rubicon`; library products `Rubicon` and `RubiconObjC`; targets `RubiconCore`, `Rubicon`, `RubiconObjC`, `RubiconTesting` (iOS Public API 8). Apps `import Rubicon`. Bundle identifier prefix `com.rubicon.analytics` for the consumer and test apps; the `os.Logger` subsystem is `com.rubicon.analytics` (iOS Logging 1). |
| D3 | Default SaaS host | The same placeholder as Android, `https://api.rubicon.example`, until the production URL is known (Android log D7). |
| D4 | License | Apache-2.0, as the Android SDK. Only the license file is needed now. |
| D5 | Version numbering and the version constant | SemVer, first release `0.1.0`, the same number line as Android for the same contract. SwiftPM generates nothing at build time, so `Sources/RubiconCore/Version.swift` holds the constant, a release script updates it, and CI fails when it differs from the tag being released (step 8.6). |
| D6 | CI runners and minutes | GitHub Actions on `macos-26` with Xcode 26.6 selected (`xcode-select`); every lane needs macOS (the core imports `zlib` and `CryptoKit`, and the simulator needs Xcode). macOS minutes count ten times against the plan: 2000 minutes a month is about 200 macOS minutes. Every pull request: format lint, `swift build`, `swift test` (core), source rules, API diff; the simulator suite and the three consumer apps only on pull requests that touch `Sources/Rubicon`, `Sources/RubiconObjC`, `Package.swift` or `ConsumerApps`, and nightly. Check the organisation's plan and the runner image's Xcode on the day. |
| D7 | Test framework | Swift Testing (`@Test`, `#expect`, `@Suite`, parameterized tests) for every new test; XCTest only where Swift Testing cannot be used: the UI tests of the consumer apps and the Objective-C test target. Both ship with Xcode 16 and later (iOS Public API 2). |
| D8 | Format and lint | `swift format` from the toolchain (lint mode in `check`, format before every commit), configured in `.swift-format`; no SwiftLint, which is a separate install. The source rules of section 5 are a shell script in `Scripts/`, as `checkSourceRules` was a Gradle task. |
| D9 | Coverage | `swift test --enable-code-coverage` and `llvm-cov export`, gated by a script: 90 percent line coverage in `RubiconCore`, 80 percent in `Rubicon` (the Android thresholds); exclusions only for the Objective-C wrapper's forwarding code, listed in the script. |
| D10 | Consumer apps and their project files | `ConsumerApps/` with three iOS apps: `Swift5App` (Swift 5 language mode), `Swift6App` (Swift 6 mode, strict concurrency, `-warnings-as-errors`), `ObjCApp` (Objective-C through `RubiconObjC`) (iOS Public API 3). An `.xcodeproj` cannot be written by hand; the projects are generated from committed `project.yml` files with XcodeGen, a development tool installed on the runner, never a dependency of the package. Alternative: committed `.xcodeproj` bundles, which merge badly. |
| D11 | Simulator matrix | The newest iOS simulator of the runner's Xcode on every run, and the oldest runtime that Xcode 26 can still install nightly; verify on the day which runtime that is, since an iOS 15 simulator may not be installable on Xcode 26, in which case the lowest installable runtime is used and iOS 15 is covered by `swift build` with the deployment target only. |
| D12 | Demo app repository | `rubicon-team/rubicon-ios-demo`, the counterpart of the Android demo app, reusing `fake-server/server.py` from the Android demo repository (phase 9). |
| D13 | Documentation build | `xcodebuild docbuild` (DocC in Xcode, no plugin dependency) in `check`; a script reads the symbol graph and fails when a public symbol has no documentation comment, the counterpart of the Dokka check. The swift-docc-plugin is not added: it would be a package dependency, even if only a plugin. |
| D14 | Scope of `RubiconObjC` in the first release | Every public verb, `RBNConfiguration` with every setting, the logger block and `RBNLogLevel`, `beforeSend` boxed with `NSException` caught (iOS Public API 6). `RBNEventUpdate` and the observer block follow the Objective-C usage survey (iOS Logging 2); the type is designed in step 7.7 and shipped if the survey says so. |
| D15 | Test HTTP server | A small HTTP/1.1 server on `NWListener` in `RubiconTesting` (about two hundred lines: one connection at a time, scripted responses, recorded requests), the counterpart of MockWebServer. No swift-nio or third-party server: test dependencies are allowed but named, and the server is small. |
| D16 | Objective-C test target | `Tests/RubiconObjCTests` as an Objective-C test target in `Package.swift` (SwiftPM builds C-family targets on Apple platforms), with XCTest, run on the simulator. If SwiftPM refuses an Objective-C test target for an iOS-only package in practice, the tests move into `ObjCApp`'s test bundle; confirm in step 1.1. |

## 4. Target layout

```
rubicon-ios-sdk/
  CLAUDE.md                     root rules (step 1.2)
  README.md                     integration guide (step 8.5)
  CHANGELOG.md
  LICENSE
  Package.swift                 swift-tools-version: 6.0, platforms: [.iOS(.v15)], swiftLanguageModes: [.v6]
  .swift-format
  Sources/
    RubiconCore/                Foundation only; no UIKit, no os.Logger, no Network, no UIApplication
      CLAUDE.md
      Version.swift
      <area>/                   see the list below; public API files at the top level of the target
    Rubicon/                    iOS; UIKit behind #if canImport(UIKit) so `swift build` on macOS compiles
      CLAUDE.md
      PrivacyInfo.xcprivacy     the one manifest (iOS Privacy 1), declared with .process
      RubiconAnalytics.swift    the factory
      Platform/                 platform implementations of the core protocols
      Lifecycle/                notifications, background task, install and update, screens, deep links
      Network/                  RubiconNetworkObserver, NWPathMonitor
    RubiconObjC/                the wrapper, Swift files with @objc classes, RBN prefix
      CLAUDE.md
    RubiconTesting/             TestPlatform fakes, virtual-time scheduler, TestHTTPServer, golden loader
  Tests/
    RubiconCoreTests/           Swift Testing, `swift test` on macOS
      Fixtures/golden/          the Android golden wire files, copied verbatim (step 1.1), refreshed by a script
    RubiconTests/               Swift Testing on the simulator: lifecycle, screens, platform, sink, manifest
    RubiconObjCTests/           Objective-C (.m), XCTest, on the simulator (D16)
  ConsumerApps/
    Swift5App/, Swift6App/, ObjCApp/   project.yml each (D10); UI tests for the simulator suite (step 8.1)
  API/                        the public API record, one text file per module (step 1.1, D-log 2026-10-11)
  Scripts/
    check.sh                    everything CI runs, in order; --all adds the simulator lane
    check-source-rules.sh       the static rules of section 5, with --self-test
    check-required-reason-apis.sh   the privacy manifest grep (iOS Privacy 1)
    check-coverage.sh, check-docs.sh, api-diff.sh, refresh-golden.sh, format.sh,
    test-simulator.sh, build-consumer-apps.sh, release.sh (step 8.6)
    lib/strip-swift.pl          blanks comments and strings before the source scans
  docs/
    implementation-plan.md      this file
    issue-codes.md              the catalogue, copied from Android with a Platform column (step 2.2)
    privacy-manifest.md         what the manifest declares and why, for customers' reviews (step 7.8)
    wire-format.md              points at the golden files; notes the number text difference (iOS Serialization 1)
  .github/workflows/, .github/pull_request_template.md
```

Internal areas in `RubiconCore`, one folder each, the same names as the Android packages: `platform`
(the protocols `Clock`, `ElapsedClock`, `RandomSource`, `FileSystem`, `NetworkMonitor`,
`HttpTransport`, `ContextProvider`, `ProcessInfo`, `LifecycleSource`, `Scheduler`), `log`, `util`
(UUIDv7, ISO time, HTTP date, SHA-256), `json`, `validation`, `config`, `event`, `storage`, `queue`
(writer, uploader, triggers), `http`, `retry`, `identity`, `session`, `context`, `privacy`, `remote`,
`diagnostics`, `pipeline`. Public types live at the top level of the target; everything else is
`internal`. Types the `Rubicon`, `RubiconTesting` and test targets need from the core are `package`
(the access level between `internal` and `public`, Swift 5.9), the counterpart of `@RubiconInternal`:
visible inside this package only, never to apps, and therefore absent from the API record by
construction (decided 2026-10-11, section 15). `@_spi` is not used.

## 5. Test strategy

Every layer below is required; the step or phase that introduces it is in brackets.

| Layer | Where | Tools | Covers |
|---|---|---|---|
| Unit | `Tests/RubiconCoreTests` | Swift Testing; fakes from `RubiconTesting`, never a mocking library | Every component in isolation through `TestPlatform` (clock, elapsed clock, random, scheduler with virtual time, network monitor, transport, context provider, process info, lifecycle source, file system seam) [2 onward] |
| Component integration | `Tests/RubiconCoreTests/Integration` | Real files under a temporary directory, the real `URLSession` transport against `TestHTTPServer`, fake clock, virtual time | The whole pipeline from `track` to the server, restarts (a new instance over the same directory), crash leftovers, the locked-device state through the `FileSystem` seam [6] |
| Wire contract | `Tests/RubiconCoreTests/Fixtures/golden` | `JSONSerialization` to produce; `JSONDecoder` as the independent parser (a separate implementation on Darwin); structural comparison with the number rule of iOS Serialization 1 | One golden file per event type and for the batch envelope, copied from Android; every line the SDK writes is valid JSON to the independent parser (Serialization 5) [3, completed in 8.4] |
| Objective-C interop | `Tests/RubiconObjCTests` | XCTest, `.m` files | Every wrapper method, configuration setter, the logger block and the boxed hook called from Objective-C; a throwing block is caught and the event dropped; compiling is half the test (iOS Public API 1) [7.7] |
| Simulator | `Tests/RubiconTests` | Swift Testing on the simulator | Factory, app-extension check, lifecycle notifications, background task, install and update dates, the swizzle and screen names, deep links, context provider, `NWPathMonitor`, the `os.Logger` sink, protected-data notifications, the privacy manifest's content [7] |
| Network observer | `Tests/RubiconTests/Network` | A real `URLSession` with a delegate against `TestHTTPServer` | Event shape, masking, host filter, pass-through, `error` values, never throws, never modifies [7.6] |
| Consumer apps | `ConsumerApps/*` | `xcodebuild build` and UI tests on the simulator | Swift 5 mode builds; Swift 6 mode builds without a warning; Objective-C builds; process kill and recovery, real offline transitions, real background expiration [8] |
| Concurrency | `Tests/RubiconCoreTests/Stress` and `swift test --sanitize=thread` | Real queues, many threads, bounded runs; Thread Sanitizer on the core tests in CI | Thread safety of every public method, per-thread ordering, no lost or duplicated events under load, backpressure counting; TSan clean [6] |
| Robustness | unit and integration | Seeded random inputs (no new library), fault-injecting file system and transport | Validator and serializer never trap on arbitrary input; storage failures, full disk, truncated files, unreadable and locked stores degrade as decided [2, 4, 6] |
| Static rules | `Scripts/check-source-rules.sh` | Plain source scan | No `print` or `debugPrint`; no `UserDefaults`; no `URLSession.shared`; no `#available`; no `Date()` in the core outside `Clock`; no `DispatchQueue.main` in the core; no `import UIKit` outside `Sources/Rubicon` and no unguarded one there; no `Task {` or `async` in public API; no `@unchecked Sendable` without a justifying comment on the line above; log calls never interpolate `properties`, `traits`, `userId`, `deviceId`, `apiKey`, `headers` or `body` (Logging 4a); the required-reason API symbols (`systemUptime`, `mach_absolute_time`, `creationDate`, `contentModificationDate`, `attributesOfItem`, `stat`, `fstat`, `volumeAvailableCapacity`, `UserDefaults`, `activeInputModes`) appear only in `Sources/Rubicon/Platform` and only for the two declared categories (iOS Privacy 1) [1, extended as areas arrive] |
| API | `Scripts/api-diff.sh` | `swift package diagnose-api-breaking-changes` against the last release tag; `package` symbols are not public and never appear | Every public change is visible in the diff and named in the pull request; nothing is public by accident [1] |
| Documentation | `Scripts/check-docs.sh` | `xcodebuild docbuild`, symbol graph | Every public symbol has a documentation comment (D13) [1] |
| Coverage | `Scripts/check-coverage.sh` | `llvm-cov` | Gate at the thresholds of D9 [1] |
| Manual | demo app with `fake-server` | Checklist in step 9.3 | What a person must see once before a release [9] |

Rules that apply to every test:

- Test names are sentences in `@Test("...")`; suites group them. No `sleep` and no real waiting in
  unit tests; time is virtual through the `Scheduler`. Integration and stress tests may wait, with a
  timeout, on a condition (`confirmation` or a semaphore with a deadline).
- Every test that touches files uses its own temporary directory. No test depends on another's order;
  Swift Testing runs suites in parallel, so nothing is global.
- Every drop reason and every issue code has at least one test that produces it and asserts the
  counter (a test enumerates `DropReason` and `Code` and fails when one has no producing test).
- Every `debug == true` `developerError` has a test with the assertion handler replaced, and the same
  input with `debug == false` has a test that asserts the log line, the code and that nothing traps.
- Every public entry point has a test that injects a failure below it and asserts the host is not
  crashed (Non-negotiable 1).
- The ports from Android (UUIDv7, ISO formatter, HTTP date, validator limits) run the Android test
  vectors, copied verbatim, so the two SDKs are proven equal where the decisions say they are.

## 6. Definition of done (every step)

- Every test listed for the step exists and passes; `Scripts/check.sh` (format lint, `swift build`
  for macOS and for the iOS simulator, `swift test` with coverage, the simulator tests when the step
  touches `Rubicon`, the source rules, the required-reason grep, the API diff, the docs check) is
  green locally and in CI.
- A public API change has its `api-diff` output in the pull request, a documentation comment on
  every new public symbol, the matching `RubiconObjC` change with an Objective-C test, and is named at
  the top of the pull request.
- No dependency beyond those in step 1.1 (none at runtime); a test-only or tool-only addition is
  named in the pull request.
- Every new WARN or ERROR has a `Code` listed in `docs/issue-codes.md`, with its Platform column;
  every new way to lose an event uses a `DropReason` and is counted.
- No value, id, key, header, body or query string reaches a log line (Logging 4a), which on iOS is
  also what makes `privacy: .public` safe (iOS Logging 1).
- Every call to a required-reason API is in `Sources/Rubicon/Platform`, under one of the two
  declared categories, or the manifest and the iOS Privacy page change first.
- `CLAUDE.md` of the affected target updated if a rule was added, changed or clarified; this file
  updated: status ticked, traceability rows filled, decisions log extended.
- No `TODO` without the step that resolves it.
- The pull request follows the template: problem, change, how it was tested, and the decisions it
  implements (for example "Queue 4, iOS Queue 1, Disk 1").

## 7. Phase 1: Repository and tooling

### 1.1 Scaffold

- Read: iOS Public API 2, 3 and 8; Android plan step 1.1 for the shape.
- Build: `Package.swift` (tools 6.0, `.iOS(.v15)`, Swift 6 language mode in every target, the four
  targets and two products, the three test targets, the privacy manifest resource); `Version.swift`;
  `.swift-format`; `Scripts/` with `check.sh` and the checks of section 5 as far as they can run on an
  empty package (format, build, test, source rules, required-reason grep, API diff against no
  baseline, docs); the golden files copied from Android with `refresh-golden.sh`; `ConsumerApps/`
  with three `project.yml` files and empty apps that import the products; GitHub Actions workflows
  (pull request lane and the simulator and consumer lane with the path filter of D6, nightly lane with
  the matrix of D11 and TSan); pull request template; `LICENSE`, `CHANGELOG.md`, `.gitignore`.
- Tests: `swift build` on macOS and for the simulator; an empty test in each test target runs;
  `ObjCApp` compiles an Objective-C file that imports `RubiconObjC` (confirms D16's target shape);
  `check.sh` is green on the empty package.

### 1.2 CLAUDE.md files

- Read: the Android root, `sdk-core` and `sdk-android` `CLAUDE.md` in full; every iOS page's
  Summary table.
- Build: the root `CLAUDE.md` (targets, commands, non-negotiables, public API, dependencies, threading,
  testing, code style, git, keeping the files honest) and `Sources/RubiconCore/CLAUDE.md`,
  `Sources/Rubicon/CLAUDE.md`, `Sources/RubiconObjC/CLAUDE.md`, each the Android rules rewritten for
  Swift with the iOS differences folded in and pointers to both pages.
- Tests: none; reviewed by the user against the pages.

## 8. Phase 2: Core foundations (no pipeline yet)

### 2.1 Platform protocols and test fixtures

- Read: iOS Queue 1 (the `Scheduler`), iOS Session 2 (`ElapsedClock`), iOS Disk 1 and 3 (the file
  system seam with the locked state), iOS Retry 1 (`NetworkMonitor`), Android log 2.1 and 5.1
  (`Platform`, `TransportSettings`).
- Port: `sdk-core/.../internal/platform/*`, `sdk-core/src/testFixtures`.
- Build: the `platform` protocols as `Sendable` protocols; `Platform` as a struct of them; the
  `Scheduler` protocol (`schedule(after:on:_:)`, `cancel`) with the real GCD implementation and the
  virtual-time `TestScheduler`; `TestPlatform` in `RubiconTesting` with every fake (`TestClock`,
  `TestElapsedClock`, `SeededRandom`, `FakeFileSystem` with fault injection and a `locked` switch,
  `FakeNetworkMonitor`, `FakeTransport`, `FakeContextProvider`, `FakeProcessInfo`,
  `FakeLifecycleSource`); `TestHTTPServer` (D15).
- Tests: the virtual scheduler runs due work in order and never early; `FakeFileSystem` reports
  `missing`, `unreadable` and `locked` as decided; `TestHTTPServer` answers a scripted response and
  records the request, including headers and the gzip body.

### 2.2 Logging infrastructure

- Read: iOS Logging 1 and 2; Logging 1 to 4; Android log 2.2.
- Port: `sdk-core/.../internal/log/*` (`Log`, `Code`, `CallbackGuard`), `docs/issue-codes.md`.
- Build: `LogLevel`, `RubiconLogger`, `Code` (every Android code, one enum), the internal `Log` with
  autoclosure messages (`log.warn(.hostBlocked) { "..." }`), level and repeat limit checked before the
  autoclosure runs, `repeatKey`; `CallbackGuard` with the `threadDictionary` flag and the atomic
  once-only switches; the no-op default sink in the core (the `os.Logger` sink is step 7.1);
  `docs/issue-codes.md` copied with a Platform column (`NETWORK_STATE_PERMISSION_MISSING` Android-only).
- Tests: a disabled level never evaluates the autoclosure; once per process per code, later at DEBUG;
  `repeatKey`; the guard ignores log lines and observer updates caused on the callback's own thread
  and lets another thread's through; the once-only switches under concurrent calls; a test
  enumerates `Code` against the catalogue file and fails on a missing row.

### 2.3 Identifiers and time

- Read: iOS Event Model 3 (lowercase UUIDv7 port), iOS Serialization 3, iOS Session 2, Retry 3.
- Port: `sdk-core/.../internal/util/{Uuid7, IsoDates, HttpDates}*` with their tests and vectors.
- Build: the monotonic UUIDv7 generator (one per instance, seeded from `RandomSource` and `Clock`,
  strictly increasing within a millisecond and across a clock that moves back, lowercase text, never
  Foundation's `UUID`); the ISO formatter over a shared `ISO8601DateFormatter` with the Android range
  rule (years 0000 to 9999, otherwise unsupported); the HTTP date parser (IMF-fixdate only, Android
  log 2.3); SHA-256 hex through `CryptoKit` for the key hash.
- Tests: the Android UUIDv7 vectors and properties (version and variant bits, timestamp equals the
  clock, 10 000 ids in one millisecond unique and ordered, ordering across a clock set back, lowercase,
  parsed by Foundation's `UUID`); the Android `IsoDates` table verbatim (epoch 0, 2024-02-29,
  2100-03-01, year boundaries, milliseconds 0 and 999, dates before 1970, the first and last supported
  instant) plus 100 000 seeded random instants against `Calendar` in UTC; RFC 9110 date examples and
  malformed inputs; SHA-256 against known digests.

### 2.4 JSON layer

- Read: iOS Serialization 1; Serialization 1 and 4; Disk 3; Android log 2.4.
- Port: `sdk-core/.../internal/json/*`.
- Build: the only code that touches `JSONSerialization`: write a compact line from a `PropertyValue`
  tree with `.sortedKeys` (`NSNull` for `null`, `NSNumber` from the typed enum so `true` and `1` stay
  apart); read the store files and check stored lines with `jsonObject(with:)` and the
  `CFBooleanGetTypeID` rule; the documented known behaviours in the comments: seventeen significant
  digits for non-integral doubles, `50` for `50.0`, `\/` escaping, `1e+21`, NaN and infinity never
  reach the writer. Events are never parsed back into objects; reading exists only for the three store
  files and for the corruption and age check of stored lines.
- Tests: `{"coupon":null}` written as such; each known behaviour pinned (so a Foundation change is
  noticed), including `49.9` as `49.899999999999999`; round trip of every `PropertyValue`; output
  parsed by `JSONDecoder`; non-ASCII and escaped characters; a 32 KB line; a store file with missing,
  extra and wrongly typed keys; trailing content after an object makes the line corrupt (Android log 2.4).

### 2.5 Property validation and normalization

- Read: iOS Public API 5, iOS Serialization 2; Serialization 2 and 3; Android log 2.5.
- Port: `sdk-core/.../internal/validation/*` and its tests.
- Build: `PropertyValue`; the normalizer in the order of the iOS table (`NSNull` and empty optional,
  `CFBoolean`, integer `objCType`s to `Int64`, `UInt64` above `Int64.max` unsupported, `Double` and
  `CGFloat`, `Float` and `Decimal` through their decimal text, `String`, `Character`, `Date` through
  the ISO formatter, `URL.absoluteString`, payload-less enums through `Mirror` and `String(describing:)`,
  arrays and `Set`, dictionaries with `String` keys, everything else unsupported); the limits
  (32 KB, 255, 1024 on a character boundary, 256 with super properties dropped first, depth 3); the WARN
  with key and type and `developerError` in debug; the second pass after the hooks.
- Tests: one test per row of the iOS table, including `Int8`, `UInt`, `CGFloat`, `Decimal(19.99)`,
  `Float(0.1)`, `Set`, `[Int: Any]`, a `CustomStringConvertible` enum and an `@objc` enum (the caveat),
  an `NSString` with a lone surrogate bridged to U+FFFD; the four boxed-boolean cases of iOS Public API 5;
  every Android limit test ported; seeded random values never trap.

## 9. Phases 3 to 6: Core

### 3.1 Configuration

- Read: iOS Configuration 1 to 3; Configuration 1 to 5; Android log 3.1.
- Port: `sdk-core/.../config/*`.
- Build: `AnalyticsConfiguration: Sendable` struct with `let apiKey`, `var host`, `var debug` from the
  build flag, `var beforeSend`, the nested group structs (`flush`, `session`, `autocapture`, `context`,
  `privacy`, `logging`, `network`) with the Android defaults; the validator (invalid `host` per Android
  log 3.1, `CLEARTEXT_HOST` with the iOS ATS sentence, reserved headers in any letter case); the
  snapshot is the struct itself; `description` never shows the key or header values.
- Tests: every Android configuration test ported; the `debug` default differs between a DEBUG and a
  release test build (two test configurations in CI); a later write to the caller's copy does not
  reach the instance.

### 3.2 Event model and public types

- Read: iOS Event Model 1 to 3, iOS Public API 6, iOS Logging 2; Event Model 1 to 5; Android log 3.2.
- Port: `sdk-core/.../Event.kt` and the pipeline's hook rules as data.
- Build: `protocol Event: Sendable` with the fixed fields, `TrackEvent`, `ScreenEvent`, `IdentifyEvent`
  structs (`let` fixed fields, `var name` and `properties` or `traits`), `EventSource`, `EventContext`
  groups as structs, `BeforeSend`, `EventObserver`, `EventUpdate`, `DropReason`, `ContextField` with
  the sixteen iOS cases, `Autocapture`, `Consent`; the hook-result rule (own kind, same source, ids,
  timestamp and context; automatic events keep name and keys).
- Tests: a hook mutates a copy and the original is unchanged; a hook result of another kind or with a
  changed id is rejected; `EventUpdate.description` never shows properties; `Equatable` on the structs
  for the tests; all public types are `Sendable` (a compile-time test in Swift 6 mode).

### 3.3 The `Analytics` protocol

- Read: iOS Public API 4 and 7, iOS Lifecycle 3 (the two `trackDeepLink` methods); Public API 2, 5, 8;
  Android log 3.3.
- Build: `protocol Analytics: Sendable` with the twelve verbs and two properties, default arguments
  through protocol extensions; `NoOpAnalytics` (`isOptedOut == true`, `deviceId == ""`).
- Tests: a test fake conforms to the protocol in a few lines; every method returns `Void` except the
  two readers; `NoOpAnalytics` accepts every call and does nothing.

### 4.1 Key-value stores

- Read: iOS Disk 1 to 3, iOS Identity 1; Disk 1, 2, 4, 6, 7; Android log 4.1 and 4.2.
- Port: `sdk-core/.../storage/{DeviceStore,PersonStore,RemoteConfigStore,AtomicFile}*`.
- Build: the three JSON stores under `Application Support/rubicon/<keyHash>/` through the `FileSystem`
  seam; atomic write (temporary file, `F_FULLFSYNC` with `fsync` fallback, rename); the three read
  states `missing`, `unreadable`, `locked` (a permission error while protected data is unavailable is
  `locked`); `isExcludedFromBackup` on the directory; `last_failure` may hold `cancelled` (iOS Retry 2);
  the shapes of Android log 4.1.
- Tests: every Android store test ported; `locked` is never overwritten, never gets a temporary id,
  never deletes or counts; `F_FULLFSYNC` failing falls back to `fsync` once with a DEBUG line; the
  directory is excluded from backup; a store with an unknown `consent` or `pause_kind` is unreadable.

### 4.2 Event store

- Read: iOS Disk 2 and 3; Disk 3, 5; Queue 4, 5; Android log 4.2.
- Port: `sdk-core/.../storage/EventStore*`.
- Build: segments under `events/v1/` named by index, sizes tracked in memory with one startup read
  through `attributesOfItem[.size]` (in the `Rubicon` platform implementation, under `C617.1`), never a
  timestamp for ordering; the open segment, rotation at the batch limits, the age and corruption check
  on read, `clear()` for deleting on purpose, the locked state (sync and close, hold, resume).
- Tests: every Android event store test ported; corrupt lines counted once when the segment is
  deleted; a full disk is `storage_error`; sizes after a restart equal the files; the locked sequence
  through the fake file system.

### 5.1 HTTP transport

- Read: iOS HTTP 1 to 4; HTTP 2 to 6; Android log 5.1 and 5.3.
- Port: `sdk-core/.../http/*` (`HttpResult`, `FailureKind` plus `cancelled`, `Retry-After` parsing,
  the blocked-host rule).
- Build: `URLSessionTransport` in the core (Foundation): one `.ephemeral` session per instance with the
  settings of iOS HTTP 1, the transport as `URLSessionTaskDelegate` refusing redirects, `uploadTask`
  and a semaphore, `invalidateAndCancel()` on shutdown; gzip through `zlib` in a `Data` extension;
  the `URLError` table to `FailureKind`; `getaddrinfo` after `connect` or `dns`; the User-Agent from
  `TransportSettings`; `X-Request-Id` for the DEBUG line; GET with `If-None-Match`, `Success.body` and
  `etag` for GET only.
- Tests: against `TestHTTPServer`: the request shape (headers, gzip body decompressed and compared,
  `Content-Length`); 200, 304, 3xx is `HttpError` with `HTTP_REDIRECT`, 429 with `Retry-After` in both
  forms and the Android edge cases (Android log 5.1); timeouts at 20 s idle and 45 s total under
  a slow server; a cancelled task is `cancelled`; a self-signed certificate is `tls`; a closed port is
  `connect`; an unknown host is `dns`; a host resolving to `127.0.0.1` is `blocked` and `localhost`
  is not; the gzip output decompresses with `gunzip`; bodies never appear in log lines.

### 5.2 Retry policy and backoff

- Read: iOS Retry 2; Retry 1 to 5; Android log 5.2.
- Port: `sdk-core/.../retry/*` (`RetryGroup`, `RetryPolicy`).
- Build: the Android policy with `ElapsedClock` for waits, the `cancelled` case (no step, no wait, no
  per-segment count, `last_failure = "cancelled"`), the poison-batch rule, the clock guard at restore.
- Tests: every Android retry test ported; `cancelled` five times in a row leaves `step` and the
  segment's attempts unchanged and the next trigger tries at once; the network's return ends only
  network waits.

### 5.3 Remote configuration

- Read: Configuration 1; Android log 5.3; `docs/remote-config.md` in the Android repository.
- Port: `sdk-core/.../remote/*`.
- Build: the contract as on Android (`enabled`, `autocapture_off`, `flush_at`, `flush_interval_ms`,
  `sample_rate`, `diagnostics_sample_rate`), ETag handling, the runtime flags, the fetch at the first
  wake with the network, once per launch.
- Tests: every Android remote configuration test ported.

### 6.1 Identity and super properties

- Read: iOS Identity 1; Identity 1 to 6; Android log 6.1.
- Port: `sdk-core/.../identity/*`.
- Build and tests: as on Android; `deviceId` before the writer has loaded the store is read once on
  the calling thread, sharing one read with the writer.

### 6.2 Session

- Read: iOS Session 1 and 2; Session 1 to 5; Android log 6.2.
- Port: `sdk-core/.../session/*`.
- Build: the session rules over `LifecycleSource` (foreground and background signals, the startup
  state) and `ElapsedClock`; the `35F9.1` note in the code comment where `systemUptime` is read (in
  `Rubicon`).
- Tests: every Android session test ported through `FakeLifecycleSource`; a process started in the
  background has no session until foreground.

### 6.3a Event pipeline

- Read: iOS Event Model 1, iOS Public API 6; Public API 4; Android log 3.2 and 6.3a.
- Port: `sdk-core/.../pipeline/*`.
- Build and tests: as on Android: hooks on the app's events and on automatic events, results that are
  not a copy, `before_send` drops, `HOOK_VIOLATION`, `developerError` in debug, `SDK Diagnostics` passes
  without hooks.

### 6.3b Writer

- Read: iOS Queue 1 and 2, iOS Disk 1; Queue 1, 2, 5; Android log 6.3b.
- Port: `sdk-core/.../queue/Writer*`.
- Build: the writer as a serial `DispatchQueue` fed by the lock-guarded bounded channel; loads the
  stores first; the locked state (`protectedDataWillBecomeUnavailable` message: sync, close, hold;
  `DidBecomeAvailable` message: drain, load if not yet loaded, resume); `willTerminate` message
  (persist the stores, at most one second); backpressure counting; the count trigger of Android log 6.3b.
- Tests: every Android writer test ported with the virtual scheduler; the locked sequence; events
  held while locked are written in order after unlock; an unlock in a process that started locked
  loads the stores then.

### 6.4 Uploader

- Read: iOS Queue 1 and 2, iOS Retry 1 and 2; Queue 1 to 4; Retry 1, 2, 6; Android log 6.4.
- Port: `sdk-core/.../queue/Uploader*`.
- Build: the uploader as a serial `DispatchQueue`; the atomic-flag signal; waits through the
  `Scheduler` and `ElapsedClock`; the network wake; the background-flush message (begin: flush until
  nothing is pending or the first failure; expiration: cancel the in-flight task); the remote
  configuration fetch at the first wake.
- Tests: every Android uploader test ported with the virtual scheduler; expiration cancels the task
  and the batch stays; a flush arriving during a wait collapses into one.

### 6.5 Privacy

- Read: iOS Privacy (inherited section); Privacy 1 to 4; Android log 6.5.
- Port: `sdk-core/.../privacy/*`.
- Build and tests: consent as a state, the upload gate, `clearLocalData()` in two parts, deleting on
  purpose; every Android privacy test ported.

### 6.6 SDK Diagnostics

- Read: Logging 5; Android log 6.6.
- Build and tests: as on Android; the property shape with sorted keys matches the golden file.

### 6.7 `DefaultAnalytics` and the core factory

- Read: iOS Public API 4; Public API 1, 2; Android log 6.7 and 7.1.
- Build: `DefaultAnalytics` (`final class`, `@unchecked Sendable` with the justification), the core
  factory taking `Platform` and the configuration, the second-instance rule (`assertionFailure` in
  debug, existing instance and ERROR in release), `flushBlocking(timeout:)` and `shutdown()` as
  `package` members for tests.
- Tests: `CoreIntegrationTest` over real files and `TestHTTPServer`: track to server, restart, crash
  leftovers, a second instance; the stress suite (section 5) and the first TSan run.

## 10. Phase 7: iOS

### 7.1 Factory, iOS platform and the log sink

- Read: iOS Public API 4 and 8, iOS Queue 2 (app extensions), iOS Disk 1 (directory and protection
  notifications), iOS Logging 1; Android log 7.1.
- Port: `sdk-android/.../AnalyticsFactory.kt`, `AndroidPlatform.kt`, `LogcatLogger.kt`.
- Build: `RubiconAnalytics.make(configuration:)`; the `.appex` check returning `NoOpAnalytics`; the
  iOS `Platform` (real clock, `systemUptime` elapsed clock under `35F9.1`, `SystemRandomNumberGenerator`,
  the file system over `FileManager` with `Application Support/rubicon/`, backup exclusion, the
  protected-data notifications and `isProtectedDataAvailable` at startup, `F_FULLFSYNC`); the
  `os.Logger` sink (`com.rubicon.analytics`, `Rubicon`, the level mapping, `privacy: .public`); the
  `willTerminate` observer.
- Tests (simulator): the factory returns a working instance; a bundle path ending in `.appex` returns
  the no-op; the directory exists, is excluded from backup and has the inherited protection class; the
  sink maps levels (asserted through a captured `OSLogStore` where available, otherwise through the
  sink's own seam); protected-data notifications reach the writer.

### 7.2 Network monitor

- Read: iOS Retry 1, iOS Context 2.
- Port: `sdk-android/.../AndroidNetworkMonitor.kt`.
- Build: `NWPathMonitor` on its own serial queue, started with the instance, never cancelled;
  `isConnected` from the last path (`.satisfied` or `.requiresConnection`), optimistic before the
  first path; listeners for the context cache, the uploader wake and the retry wait.
- Tests (simulator): the monitor starts and delivers a path; the fake path states map as decided;
  listeners are called on the monitor's queue and never block it.

### 7.3 Context provider

- Read: iOS Context 1 and 2; Context 1 to 6; Android log 3.1 and 7.3.
- Port: `sdk-android/.../AndroidContextProvider.kt`.
- Build: every field from its iOS source (`utsname.machine`, `UIDevice`, `Bundle`, `UIScreen.nativeBounds`
  static, the locale as `preferredLocalizations.first` plus `regionCode`, the time zone, the network type
  from the shared monitor); `os.api_level` and `network.carrier` never produced; `disabledFields`.
- Tests (simulator): every field present with the right type; the two absent fields are absent; the
  locale rule against a table; `disabledFields` removes exactly the field.

### 7.4 Lifecycle, background task, install and update

- Read: iOS Session 1, iOS Queue 2, iOS Lifecycle 4 and its "to be verified with Apple" block;
  Automatic Lifecycle Events 1 to 4; Android log 7.4.
- Port: `sdk-android/.../lifecycle/*`.
- Build: `willEnterForeground` and `didEnterBackground` observers with the main-thread
  `applicationState` read at startup; `beginBackgroundTask(withName: "rubicon.flush")` around the
  background flush with the expiration handler cancelling the task; install and update detection from
  the `Library` directory and `Bundle.main.bundleURL` creation dates (`|diff| < 60 s` is an install;
  under `C617.1`; the 24-hour fallback written but switched off until Apple confirms); `Application
  Opened` and `Application Backgrounded`.
- Tests (simulator): the notification sequence produces the decided events; a process launched in the
  background; the background task begins and ends; expiration cancels the task; install versus update
  from fabricated dates through the file system seam; the version record after an update.

### 7.5 Screens and deep links

- Read: iOS Lifecycle 1 to 3; Automatic Lifecycle Events 5, 6; Privacy 5b.
- Build: the one swizzle of `UIViewController.viewDidAppear`, installed only when `screenViews` is on,
  idempotent across instances; `ScreenNamed`; names from the class otherwise, `UIHostingController` and
  system containers skipped; the last screen re-sent on return from the background; `trackDeepLink(_:referrer:)`
  and `trackDeepLink(_ activity:)` with the `utm_*` allowlist and the gate.
- Tests (simulator): a presented controller produces one `Screen Viewed`; a `ScreenNamed` controller
  uses its name; `UIHostingController` produces nothing; re-send on foreground; the swizzle is
  installed once with two instances; a universal link activity produces the event, a non-browsing
  activity does not; `utm_*` only; the gate.

### 7.6 Network request capture

- Read: iOS Lifecycle 5, iOS HTTP 3 (the `error` values); Automatic Lifecycle Events 7; Privacy 5c;
  Android log 7.6.
- Port: `sdk-android/.../network/*` (`NetworkErrors`, masking).
- Build: `RubiconNetworkObserver(analytics:hosts:maskPathIds:)` fed from the app's session delegate
  methods, metrics kept per task weakly, the event on completion, the `error` values (`canceled`,
  `timeout`, `unknown_host`, `connect`, `tls`, `url_error_<code>`), masking, host filter, never the
  SDK's own requests.
- Tests: against `TestHTTPServer` with a real delegate session: event shape and golden comparison;
  masking table; host filter; the `error` values from induced failures; never throws, never modifies.

### 7.7 The Objective-C wrapper

- Read: iOS Public API 1, 6 and 7, iOS Logging 1 and 2, D14.
- Build: `RBNAnalytics`, `RBNConfiguration` and its groups, `RBNEvent` classes, `RBNLogLevel`, the
  logger block, the boxed `beforeSend` with `NSException` caught and `before_send`, `RBNEventUpdate`
  and `RBNDropReason` (shipped per D14); every call forwards to the Swift instance.
- Tests (Objective-C, XCTest): every method and setter called from a `.m` file; a block that raises
  drops the event with `before_send`; a logger block receives the levels; the wrapper's API diff
  baseline.

### 7.8 Privacy manifest

- Read: iOS Privacy 1; `docs/privacy-manifest.md` to be written here.
- Build: `Sources/Rubicon/PrivacyInfo.xcprivacy` with the content of the iOS Privacy table; the
  required-reason grep finalised against the real sources; `docs/privacy-manifest.md`.
- Tests: the manifest parses and contains exactly the decided keys, types, flags and reasons; the grep
  passes; a deliberately added `UserDefaults` call in a scratch file fails the grep (tested in the
  script's own test).

## 11. Phase 8: Hardening and release readiness

### 8.1 Consumer apps and the simulator suite

- Read: iOS Public API 3 and 8, iOS Queue 2.
- Build: the three apps track, flush and show the observer's updates; UI tests on the simulator for
  process kill and recovery over the same files, offline to online with `NWPathMonitor` (through the
  simulator's network conditioner or the fake monitor), a real background expiration, a second
  instance guard; the nightly matrix of D11 and TSan.
- Tests: the suite itself; `Swift6App` builds with `-warnings-as-errors`; `Swift5App` builds; `ObjCApp`
  builds and its tests pass.

### 8.2 Swift 5 and Swift 6 language-mode clients

- Build and tests: a sample `beforeSend` and logger in each app compile under each mode; the public
  types are `Sendable` from the Swift 6 app (a compile-time test); the warnings of a Swift 5 client
  are documented.

### 8.3 App extension

- Build: a widget extension target in `Swift6App` that creates the SDK and gets the no-op instance.
- Tests: the extension's test asserts `isOptedOut == true`, `deviceId == ""`, no files created.

### 8.4 Wire contract complete

- Build: one golden file per event type and the batch envelope compared structurally (iOS
  Serialization 1), including `Network Request` and `SDK Diagnostics`; `docs/wire-format.md` with the
  number text note; `refresh-golden.sh` fails CI when the Android files changed and the copies did not.
- Tests: every golden file has a producing test; the independent parser accepts every line.

### 8.5 Documentation

- Build: `README.md` as the integration guide: installation (SwiftPM only), the `Rubicon.Analytics`
  qualification next to Firebase, the consent section with both states and a consent platform
  example, the on-prem section (`http` hosts and `NSExceptionDomains`, custom CA, `NSPinnedDomains`),
  the privacy label table (iOS Privacy 1), the enum caveat of iOS Serialization 2, the Objective-C
  section, the observer for QA screens, `URLSession.shared` cannot be captured; DocC for every public
  symbol; `CHANGELOG.md`.
- Tests: `check-docs.sh` green; the README snippets compile in `Swift6App`.

### 8.6 Release (after D1 to D16 are answered)

- Build: `release.sh` (version constant, tag, API baseline, changelog check); the first tag `0.1.0`;
  the API diff baseline recorded.
- Tests: CI's release lane runs `check.sh` on the tag and verifies the version constant.

## 12. Phase 9: Demo app and backend (in the demo repository)

### 9.1 Fake backend

- Reuse `fake-server/server.py` from the Android demo repository; add the iOS User-Agent and the
  `url_error_<code>` values to its checks; it accepts gzip, answers 200, 429 with `Retry-After`, 3xx
  and 503 on demand.

### 9.2 Demo app on the SDK

- A SwiftUI app with the SDK, a diagnostics screen built on `eventObserver`, screens with `ScreenNamed`
  and a `UIHostingController`-embedded flow, a deep link, a network call through a delegate session
  with `RubiconNetworkObserver`, consent toggles, `clearLocalData`.

### 9.3 Manual scenario checklist

- Install and first launch; update; kill and relaunch; airplane mode on and off; background for
  thirty seconds and more; device lock with `complete` protection in a build that opts into it; an
  `http` host without an ATS exception; a wrong key; a 429; a redirecting host; opt-out, pending
  consent, `clearLocalData`; the privacy report in Xcode; the Console filter on the subsystem.

## 13. Traceability

Every iOS decision is implemented in a step and verified by at least one named test; the inherited
Android decisions are traced through the ported tests, which keep the Android names where they
exist. When a step is done, fill the Test column of its rows with the suite and test names. A row
without a test blocks the release.

| Decision | In short | Steps | Tests |
|---|---|---|---|
| iOS Public API 1 | Swift-first API, `RubiconObjC` wrapper in the first release | 1.1, 7.7 | `RubiconObjCTests` (Objective-C, XCTest) runs on the simulator; `ObjCApp` compiles `@import RubiconObjC` |
| iOS Public API 2 | iOS 15, tools 6.0, no `#available` | 1.1 | `check.sh` builds every target for `arm64-apple-ios15.0-simulator`; source rule `no-available` with its self-test |
| iOS Public API 3 | Swift 6 mode, `Sendable` public types, `@Sendable` hooks, no `async`; Swift 5 and 6 clients | 1.1, 3.2, 8.2 | `swiftLanguageModes: [.v6]`; `Swift5App` and `Swift6App` (strict concurrency, warnings as errors) build; source rules `no-async-public-api`, `no-task-public-api`, `unjustified-unchecked-sendable` |
| iOS Public API 4 | `RubiconAnalytics.make(configuration:) -> any Analytics` | 7.1, 6.7 | `NoOpAnalyticsTests` (a fake conforms in a few lines; the no-op reports opted out and an empty id); the factory in 7.1; `CoreIntegrationTests` (`RubiconCore.create` over real files and `TestHTTPServer`: a second instance returns the first with `SECOND_INSTANCE` and is a developer error in debug; an unusable configuration gives the no-op; the public `RubiconAnalytics.make` wraps it in 7.1); `RubiconAnalyticsTests` (simulator: `RubiconAnalytics.make` returns a working instance over real files and the real transport; the `.appex` bundle gets the no-op with one INFO line; the platform touches no file; the default root is `Application Support/rubicon`) |
| iOS Public API 5 | `[String: Any]` to `PropertyValue`, `CFBooleanGetTypeID` | 2.5 | `PropertyNormalizerConversionTests` (the four boxed-boolean cases, `PropertyValue` as the output); the `[String: Any]` entry points in 3.3 |
| iOS Public API 6 | `BeforeSend` closure, value-type `Event`, no `throws`; wrapper catches `NSException` | 3.2, 6.3a, 7.7 | `EventModelTests` (a hook mutates its copy, the original is unchanged), `HookRulesTests`; the pipeline in 6.3a; `EventPipelineTests` (hooks in list order on a value copy; `nil` drops quietly; the automatic-event rules; no throwing path exists) |
| iOS Public API 7 | Labels, properties, `Analytics`, `RubiconAnalytics`, `Rubicon`, `RBN` | 3.3, 7.7 | `NoOpAnalyticsTests` (the twelve verbs and two properties, unlabeled first arguments, default arguments through the protocol extension), `API/RubiconCore.txt` |
| iOS Public API 8 | Three targets, iOS only, SwiftPM, zero dependencies, API diff | 1.1 | `Package.swift` has no dependencies; `api-diff.sh` records the public symbols per module in `API/` and runs `diagnose-api-breaking-changes` once a tag exists; source rule `no-uikit-outside-rubicon` |
| iOS Event Model 1 | Protocol with three structs | 3.2, 6.3a | `EventModelTests` (copy semantics, fixed fields constant, descriptions, Sendable), `HookRulesTests` (own kind, fixed fields, automatic rules, foreign conformance); `EventPipelineTests` (the Android `EventPipelineTest` ported: `HookRules` applied in the pipeline; a third-party `Event` conformance and a rebuilt event are dropped with `HOOK_VIOLATION`; a breach is a developer error in debug) |
| iOS Event Model 2 | `Date` in memory, epoch ms on the wire | 3.2, 2.4 | `EventGoldenTests` (`timestamp` and `started_at` as epoch milliseconds from `Date`) |
| iOS Event Model 3 | Lowercase UUIDv7 port | 2.3 | `UuidV7GeneratorTests` (version and variant, timestamp field, 10 000 in one millisecond, clock back, overflow, scripted draws give known ids, many threads, lowercase parsed by Foundation `UUID`) |
| iOS Configuration 1 | Struct, no freezing | 3.1 | `ConfigurationDefaultsTests`, `ConfigValidatorTests` (value semantics: later writes never reach the snapshot; every value reaches it) |
| iOS Configuration 2 | `debug` default from the build flag; `developerError` | 3.1, 2.2 | `ConfigurationDefaultsTests` (`defaultDebug` follows `#if DEBUG`; the nightly release-configuration run flips it), `ConfigValidatorTests` (developer errors recorded in debug, clamping and logging in release) |
| iOS Configuration 3 | `host: String` validated | 3.1 | `ConfigValidatorTests` (the Android host table accepted and rejected, trailing slash, `http://` WARN naming App Transport Security) |
| iOS Identity 1 | Files excluded from backup; no Keychain, no IDFV | 4.1, 6.1, 7.1 | `DeviceStoreTests` (a missing file gets a new id from the shared generator's closure; unreadable keeps a temporary id and never writes; locked mints nothing), `FileKeyValueStoreTests` (directory excluded from backup), `IdentityTests` (the Android `IdentityTest` ported: `identify rules`, `invalid user ids`, `reset and super properties`, `ordering`, `device id`; plus `clearLocalData` keeps consent, versions and remote config; `deviceId` is empty before the first unlock and calls apply after it) |
| iOS Context 1 | Field sources; no `api_level`, no `carrier`; the locale rule; sixteen fields | 7.3 | |
| iOS Context 2 | `screen` static; network type from the shared monitor | 7.2, 7.3 | `PathNetworkMonitorTests.typeMapping` (`wifi`, `cellular`, `ethernet` in that order, `nil` offline or unknown) |
| iOS Session 1 | `willEnterForeground`, `didEnterBackground`, startup `applicationState` | 7.4, 6.2 | `SessionManagerTests` (the Android `SessionManagerTest` ported: the manager sees only foreground and background calls; a process started in the background has no session until the foreground) |
| iOS Session 2 | `systemUptime` under `35F9.1` | 7.1, 2.1, 7.8, 6.2 | `FakeClocksTests` (elapsed clock only moves forward); the real clock in 7.1; `SessionManagerTests` (background time and the maximum on the injected `ElapsedClock`; a wall-clock change in the background does not count); `PlatformPartsTests.uptimeClock` (the real `systemUptime` clock in `Platform/`, under `35F9.1`) |
| iOS Lifecycle 1 | One swizzle, `viewDidAppear`, behind `screenViews` | 7.5 | |
| iOS Lifecycle 2 | `ScreenNamed`, class names, `UIHostingController` skipped, re-send on foreground | 7.5 | |
| iOS Lifecycle 3 | Two `trackDeepLink` methods, the gate | 3.3, 7.5, 6.7 | `DeepLinkTests`, `CoreIntegrationTests.deepLinks` (the two `trackDeepLink` methods on the real instance: the `utm_*` allowlist, the referrer as a bundle id or the linking page's host, a non-browsing activity ignored, the `deepLinks` gate) |
| iOS Lifecycle 4 | Install and update from file dates under `C617.1`; fallback; Apple verification | 7.4, 7.8, 6.3b | `AppLifecycleTests` (the Android `AppLifecycleTest` ported with the 60-second rule; a missing date writes nothing and checks again; the `libraryDateOnly` fallback) |
| iOS Lifecycle 5 | `RubiconNetworkObserver` | 7.6 | |
| iOS Queue 1 | Two serial queues, bounded channel, atomic flag, `Scheduler` | 2.1, 6.3b, 6.4 | `TestSchedulerTests` (due order, never early, cancellation, re-entrant work), `GCDSchedulerTests` (serial per worker, `assertOn`); `WriterTests` (the Android `WriterTest` ported over the virtual `TestScheduler`: call order, the bounded channel and `backpressure`, the six triggers, the conflated signal); `UploaderTests` (the Android `UploaderTest` ported: one request in flight under a burst of signals, waits as cancellable items on the uploader queue, the network's return ending a network wait) |
| iOS Queue 2 | Background task, expiration cancels, `willTerminate`, `.appex` no-op | 6.3b, 6.4, 7.1, 7.4, 8.3 | `WriterLockedTests.willTerminate` (the writer syncs and writes the stores, no upload); the background task itself in 7.4; `UploaderTests` (`beginBackgroundFlush` is told when the drain ends, at nothing pending or the first failure, or at once when the uploader cannot run; `expireBackgroundFlush` cancels the request in flight); `RubiconAnalyticsTests.appExtension`; `PlatformPartsTests` (the `willTerminate` notification reaches the listener) |
| iOS Disk 1 | Host protection class inherited; the locked state | 4.1, 4.2, 6.3b, 7.1 | `FakeFileSystemTests` (`locked` is `permissionDenied` for every operation but `exists`), `PosixFileSystemTests` (`notFound` apart from I/O errors); `FileKeyValueStoreTests`, `DeviceStoreTests`, `PersonStoreTests` (`locked` reads and writes: nothing loaded, nothing minted, nothing counted, the change kept and written after unlock); `FileEventStoreFailureTests` (`suspend`, `append` and `writeBatch` locked, `open` deferred); the writer's handling in 6.3b; `WriterLockedTests` (events held in the channel while locked and written in order after the unlock; a process started locked loads the stores at the unlock; a missing file mints the id in memory, an unreadable one gives "" until the unlock; the protected-data messages pass a full channel); `RubiconAnalyticsTests.directoryAttributes` (excluded from backup, never `.complete`); `PlatformPartsTests.notifications` (the protected-data notifications reach the listener once per change) |
| iOS Disk 2 | `F_FULLFSYNC` with `fsync` fallback | 4.1 | `FileKeyValueStoreTests` (a failed sync never reaches the file; `.tmp`, sync, rename); `PosixFileSystemTests` (`F_FULLFSYNC` with the `fsync` fallback flag) |
| iOS Disk 3 | No timestamps, sizes in memory, one startup size read, no disk space API | 4.2, 7.8 | `FileEventStoreTests` (indexes from names, sizes from what the writer wrote, no timestamp or size read at all; `envelope.json` body) |
| iOS Serialization 1 | `JSONSerialization` with `.sortedKeys`; the number text warning; structural golden | 2.4, 8.4 | `JsonTests` (every value type, sorted compact output, `{"coupon":null}`, the pinned behaviours `50`, `\/`, `49.899999999999999`, `1e+21`, NaN refused; round trips; `JSONDecoder` as the independent parser; typed reads; fragments and trailing content rejected) |
| iOS Serialization 2 | The Swift conversion table; the enum caveat | 2.5 | `PropertyNormalizerConversionTests` (one test per row: integer widths, `UInt64` over range, `Float` and `Decimal` text, `CGFloat`, `Character`, `Date`, `URL`, enums incl. the `CustomStringConvertible` and `@objc` caveats, sets and slices, non-string keys, bridged lone surrogate, unsupported types), `PropertyNormalizerLimitTests` (every limit at, below and above), `PropertyProblemReportingTests`, `PropertyNormalizerFuzzTests` |
| iOS Serialization 3 | `ISO8601DateFormatter`, range rule, Android vectors | 2.3 | `IsoDatesTests` (the Android vectors incl. years 0000 and 9999, range rule, 100 000 instants against `Calendar` from 1583 on, day round trip over the range); see the 2026-10-11 log row on the Julian cutover |
| iOS HTTP 1 | Ephemeral session, 20 s and 45 s, redirects refused, semaphore | 5.1 | `TransportRequestTests` (ephemeral session, headers, `Content-Length`), `TransportResponseTests` (redirect delivered as the response, 304), `TransportFailureTests` (request and resource timeouts, `cancelCurrent`) |
| iOS HTTP 2 | gzip through `zlib` | 5.1 | `TransportRequestTests` (gzip body decompressed and compared, header bytes `1f 8b`, uncompressed fallback with `COMPRESSION_FAILED`), `HostResolverTests` (gzip round trip) |
| iOS HTTP 3 | `URLError` to `FailureKind`, `cancelled`, ATS as `tls`, blocked host, observer `error` values | 5.1, 7.6 | `TransportFailureTests` (the whole `URLError` table, `cancelled`, `dns`, `connect`, `io`, `unexpected`, blocked host through an injected resolver, localhost and IP literals skipped), `HostResolverTests` |
| iOS HTTP 4 | User-Agent; TLS, pinning and proxies through the platform | 5.1, 8.5 | `TransportRequestTests` (`User-Agent: rubicon-ios/0.1.0 (iOS 17.5.1)`); ATS through the mapping only, the real refusal needs an app (8.1) |
| iOS Retry 1 | `NWPathMonitor`, `.requiresConnection` connected, optimistic start | 7.2 | `FakeSignalsTests` (listener tokens, only changes heard); the real monitor in 7.2; `PathNetworkMonitorTests` (`.satisfied` and `.requiresConnection` connected, `.unsatisfied` not; optimistic before the first path; listeners hear connectivity changes once each; the real `NWPathMonitor` starts once and delivers a path on the simulator) |
| iOS Retry 2 | `systemUptime` for waits; `cancelled` as waiting | 5.2, 6.4 | `RetryBackoffTests` (waits on the elapsed clock while the wall clock moves back), `RetryDecisionTests` (`cancelled` five times leaves step, wait and attempts unchanged, `last_failure` is `cancelled`, the next trigger tries at once), `RetryPersistenceTests` (clock guard at restore); `UploaderTests.expiration` (a cancelled upload keeps the batch, advances nothing, records `cancelled`, ends the drain, and the next signal sends at once) |
| iOS Privacy 1 | The manifest; the label table; the required-reason grep | 1.1, 7.8, 8.5 | `PrivacyInfo.xcprivacy` declared as a resource; `check-required-reason-apis.sh` |
| iOS Logging 1 | Closure logger, `os.Logger` sink, level mapping, `privacy: .public`, no `print` | 2.2, 7.1 | `LogTests` (closure logger, level gating, repeat limit, `repeatKey`, no-op default); the `os.Logger` sink in 7.1; `PlatformPartsTests.sinkMapping` (`error` to `.error`, `warn` to `.default`, the notice level, `info` to `.info`, `debug` to `.debug`; an error named by domain and code only; the subsystem and category) |
| iOS Logging 2 | `EventObserver` enum, `RBNEventUpdate`, `threadDictionary` guard, trap rule | 2.2, 3.2, 7.7 | `LogTests` (thread-dictionary re-entrancy guard, other threads unaffected, failure reports switch once); `EventUpdate` in 3.2, the wrapper in 7.7 |
| Android decisions, all pages | Inherited unchanged | the ported tests of every step | |

## 14. Status

- [x] 0 Open decisions D1 to D16 answered and recorded in section 15
- [x] 1.1 Scaffold
- [x] 1.2 CLAUDE.md files
- [x] 2.1 Platform protocols and test fixtures
- [x] 2.2 Logging infrastructure
- [x] 2.3 Identifiers and time
- [x] 2.4 JSON layer
- [x] 2.5 Property validation and normalization
- [x] 3.1 Configuration
- [x] 3.2 Event model and public types
- [x] 3.3 The `Analytics` protocol
- [x] 4.1 Key-value stores
- [x] 4.2 Event store
- [x] 5.1 HTTP transport
- [x] 5.2 Retry policy and backoff
- [x] 5.3 Remote configuration
- [x] 6.1 Identity and super properties
- [x] 6.2 Session
- [x] 6.3a Event pipeline
- [x] 6.3b Writer
- [x] 6.4 Uploader
- [x] 6.5 Privacy (the controller; its writer-level tests land with 6.3b)
- [x] 6.6 SDK Diagnostics (the event; its writer-level tests land with 6.3b)
- [x] 6.7 `DefaultAnalytics` and the core factory
- [x] 7.1 Factory, iOS platform and the log sink
- [x] 7.2 Network monitor
- [ ] 7.3 Context provider
- [ ] 7.4 Lifecycle, background task, install and update
- [ ] 7.5 Screens and deep links
- [ ] 7.6 Network request capture
- [ ] 7.7 The Objective-C wrapper
- [ ] 7.8 Privacy manifest
- [ ] 8.1 Consumer apps and the simulator suite
- [ ] 8.2 Swift 5 and Swift 6 language-mode clients
- [ ] 8.3 App extension
- [ ] 8.4 Wire contract complete
- [ ] 8.5 Documentation
- [ ] 8.6 Release
- [ ] 9.1 Fake backend
- [ ] 9.2 Demo app on the SDK
- [ ] 9.3 Manual scenario checklist

## 15. Implementation decisions log

Decisions taken during implementation that the Confluence pages do not cover, and changes to
decisions. One row each: date, step, question, answer, pages or rules updated. Rows that affect
both SDKs are mirrored into the Android plan's log after the user agrees.

| Date | Step | Question | Answer | Updated |
|---|---|---|---|---|
| 2026-10-07 | 0 | Where the repository lives | `~/Projects/rubicon-ios-sdk`, created with this plan and the `CLAUDE.md` seed; remote and branch model pending D1. | - |
| 2026-10-11 | 0 | D1-D16 | All sixteen recommendations in section 3 approved as written by the user (repository `rubicon-team/rubicon-ios-sdk`, `master`/`develop`/`feature/*` with squash merge; package `Rubicon` with products `Rubicon` and `RubiconObjC`, bundle id prefix `com.rubicon.analytics`; placeholder host; Apache-2.0; SemVer 0.1.0 with a hand-maintained `Version.swift` checked against the tag; CI lanes and path filters; Swift Testing; `swift format`; llvm-cov 90/80; XcodeGen consumer apps; simulator matrix; demo repository `rubicon-team/rubicon-ios-demo`; `xcodebuild docbuild`; full ObjC wrapper; `NWListener` test server; SwiftPM ObjC test target). | section 3 (closed) |
| 2026-10-11 | 0 | Which Xcode the SDK is built and tested with | Apple's Xcode support table (developer.apple.com/support/xcode, fetched 2026-10-11): Xcode 27 (macOS Tahoe 26.6 or later) accepts deployment targets and simulators of iOS 17 or later only; Xcode 26.6 (macOS Tahoe 26.2 or later) and Xcode 26.3 (the last that runs on macOS Sequoia 15.6) keep iOS 15. The floor is iOS 15 (iOS Public API 2), so the SDK is built and released with Xcode 26.x until the floor changes; `swift-tools-version` stays 6.0. D6 and D11 read "Xcode 26.6" where they say "Xcode 26"; the GitHub runner image is `macos-26`, whose default Xcode has been 26.6 since 2026-07-21 (actions/runner-images issue 14344). Raising the floor to iOS 17 and moving to Xcode 27 is a Confluence change (iOS Public API 2), not a plan change. | D6, D11 |
| 2026-10-11 | 0 | Local toolchain versus release toolchain | The user's Mac runs macOS 27.0.1, on which Xcode 26.x does not launch, so local development uses Xcode 27 (Swift 6.4, iOS 17 or later simulators only). The release toolchain stays Xcode 26.6 on the `macos-26` runner: it is the only one that can build for the iOS 15 floor and boot an iOS 15 or 16 simulator, so CI is the gate for both and release artifacts are never built locally. `swift-tools-version` 6.0 and Swift 6 language mode keep the sources inside what both compilers accept; a local build that passes and a CI build that fails is handled in CI, not by raising the local toolchain's status. Whether the floor moves to iOS 17 (which would make Xcode 27 the release toolchain) is a Confluence question for iOS Public API 2, raised with the business separately. | D6, D11, CLAUDE.md commands (1.1) |
| 2026-10-11 | 1.1 | Branch and commit granularity | One branch and pull request per phase, one commit per step, each commit made after the user reviewed the step; the user asked for this to keep the number of pull requests close to the Android repository's phases rather than its steps. | Working agreement 2, root `CLAUDE.md` |
| 2026-10-11 | 1.1 | D16 confirmed | SwiftPM accepts an Objective-C test target (`Tests/RubiconObjCTests`, `.m` files, XCTest) in the iOS-only package; `xcodebuild test -scheme Rubicon-Package` on the iOS 27 simulator ran it and the Swift Testing target. The Objective-C tests stay in the package. | - |
| 2026-10-11 | 1.1 | Code style | `swift format` with 4-space indentation and 120 columns (the Xcode defaults and what the five reference SDKs use), documentation and trap rules (`AllPublicDeclarationsHaveDocumentation`, `NeverForceUnwrap`, `NeverUseForceTry`, `NeverUseImplicitlyUnwrappedOptionals`) on in `Sources/` and off under `Tests/` and `ConsumerApps/` through their own `.swift-format`. | - |
| 2026-10-11 | 1.1 | What the API check records | `diagnose-api-breaking-changes` reports breakages only, and only against a tag. To make every public change visible and nothing public by accident, `api-diff.sh` also writes the public symbols of each module (from `swift package dump-symbol-graph`, SPI symbols left out) to `API/<module>.txt` and fails when the committed record differs; `--update` is the counterpart of `apiDump`. Breakages against the last tag are allowed only through `Scripts/api-breakage-allowlist.txt`. | Plan section 5 (API row) |
| 2026-10-11 | 1.1 | Where the documentation check runs | The undocumented-symbol check reads the symbol graph from `swift package dump-symbol-graph` and runs in every lane; `xcodebuild docbuild` runs in the simulator lane (`check-docs.sh --build`), because it needs an iOS destination and costs macOS minutes. D13 is implemented in two places, not one. | D13 |
| 2026-10-11 | 1.1 | Runner image facts | `macos-26` (macOS 26.6.1) ships Xcode 26.0.1 to 26.6 with 26.6 the default, simulator runtimes iOS 26.2, 26.4 and 26.5, and no XcodeGen (installed with Homebrew in the simulator lane). The nightly "oldest" lane installs iOS 15.5 with `xcodebuild -downloadPlatform iOS -buildVersion 15.5`; unverified until the first nightly run, which decides D11's oldest runtime. | D6, D11 |
| 2026-10-11 | 1.1 | Source rules in a shell script | The rules of section 5 that can be checked on an empty package are in `check-source-rules.sh` (ten regex rules plus the guarded-UIKit and justified-`@unchecked Sendable` checks); comments and strings are blanked by `lib/strip-swift.pl` with interpolations kept, as Android's `SourceScanner` kept template expressions. `--self-test` plants one violation per rule and is run by `check.sh`. The log-value rule looks inside `log.<level>(...)` and `logger.<level>(...)` calls; step 2.2 renames it to the real logger. | Plan section 5 |
| 2026-10-11 | 1.1 | License holder | `LICENSE` is the verbatim Apache-2.0 text from apache.org without a copyright line; the legal entity to name in `NOTICE` and in the file headers, if any, is for the user to supply. | D4 |
| 2026-10-11 | 1.1 | Cross-target visibility inside the package | `package` access level instead of `@_spi(RubiconInternal)`: what the `Rubicon`, `RubiconTesting` and test targets need from the core is `package`, which no app can see and which is not `public`, so it cannot leak into the API record or the breaking-change diagnosis; `@_spi` is an underscored attribute and leaves the symbol public. Chosen by the user over the plan's original SPI wording. | Plan section 4, section 5 (API row), step 6.6 |
| 2026-10-11 | 1.2 | Android rules not carried over | Rules that exist only because of the JVM or Android were dropped rather than translated: the freezing property delegate and its diagnostic (a struct snapshot cannot be written to, iOS Configuration 1); `@Volatile`, `synchronized(this)` and deep copies at boundaries (value types and `Sendable`); `java.time`, `compileOnly`, `animalsniffer`, OkHttp version rules, `consumer-rules.pro`, Robolectric conventions, the `ACCESS_NETWORK_STATE` fallback, the main-process check (replaced by the app-extension check), `@JvmOverloads` and `@JvmStatic` (replaced by the Objective-C wrapper's rules). Every other seed rule has a counterpart in one of the four files. | - |
| 2026-10-11 | 1.2 | Line counts | Root 198 lines, `Rubicon` 154, `RubiconObjC` 44, `RubiconCore` 233: the core file is above the 200-line rule because iOS adds the locked-device state, the `URLSession` and `zlib` settings and the `cancelled` kind to the Android content. The user accepted it: the limit for that file is 250 lines, the others keep 200. | Root `CLAUDE.md` (Keeping these files honest) |
| 2026-10-11 | 1.2 | First CI run (PR #1) | `check` 1 min 25 s, `simulator and consumer apps` 4 min 44 s on `macos-26` with Xcode 26.6; both lanes about 6 macOS minutes, about 60 plan minutes, for a pull request that touches the iOS side. The simulator suite, XcodeGen from Homebrew and the three consumer apps passed on the first run. `check-docs.sh --build` failed: `swift package dump-symbol-graph` on SwiftPM's native build system walks the test host module too and fails when it is not built; the scripts now run `swift build --build-tests` first and read the output directory from the command's own message (it is `.build/out/symbolgraph` under Xcode 27's build system and `.build/arm64-apple-macosx/symbolgraph` under 26.6). The three `CLAUDE.md` files in source targets are excluded in `Package.swift` so SwiftPM stops warning about unhandled files. | D6 (budget input), Scripts |
| 2026-10-11 | 2.1 | Steps 2.1 to 5.3 in one pull request | The user asked for phases 2 to 5 on one branch (`feature/core-foundations`) and one pull request, one commit per step, committed without a review stop; questions are still asked when a decision is missing. The per-commit review returns from phase 6 on. | Working agreement 2 and 6, root `CLAUDE.md` |
| 2026-10-11 | 2.1 | `RubiconTesting` visibility | The target is never a product, so its types are `package`, not `public`: a `public` type cannot expose `package` parameters, and nothing outside the package may see the fakes. | - |
| 2026-10-11 | 2.1 | `ProcessFacts`, `LifecycleEvent`, listener tokens | The Android `ProcessInfo` is `ProcessFacts` (Foundation owns the name) with `osVersion`, `isAppExtension` (the iOS counterpart of `isMainProcess`) and `installedApp()` returning the two file dates of iOS Lifecycle 4. `LifecycleSource` reports a `LifecycleEvent` enum (`foreground`, `background`, `willTerminate`, `protectedDataWillBecomeUnavailable`, `protectedDataDidBecomeAvailable`) and `isProtectedDataAvailable`, so iOS Disk 1 and iOS Queue 2 need no second source. Listeners are `@Sendable` closures and `addListener` returns a token whose `cancel()` removes them; there is no `removeListener`. `NetworkMonitor.start()` takes no log: starting cannot fail on iOS. `TransportSettings` gains the instance's log in 2.2. | - |
| 2026-10-11 | 2.1 | File sizes without `stat` | The core's `PosixFileSystem.fileSize` opens the file and uses `lseek(SEEK_END)`, which is not on Apple's required-reason list, so the core calls no listed API and the source-rules grep passes. Question for the user (asked in the step report): keep the `Rubicon` platform's startup size read on `attributesOfItem` under `C617.1` as iOS Disk 3 says, or use the same `lseek` path everywhere and leave `C617.1` to install detection alone (recommended). | iOS Disk 3 (if the user agrees) |
| 2026-10-11 | 2.1 | `TestHTTPServer` | `NWListener` bound to `127.0.0.1` through `requiredLocalEndpoint`; the connection handler must be set before `start`, or the listener fails with `EINVAL`; every response carries `Connection: close` and the connection is closed after it. `URLSession` retries a GET whose connection dropped, so tests of the `io` kind use a POST. | - |
| 2026-10-11 | 2.1 | Symbol graphs and re-exports | `Rubicon` re-exports the core, so its symbol graph repeats the core's public symbols, and synthesized members (`init(rawValue:)`) carry no source location. `api-diff.sh` and `check-docs.sh` keep only symbols whose location is under `Sources/<module>/`, so each record lists what its module declares and the docs check asks only for comments the author can write. `swift-format`'s one-line-summary rule is off: multi-sentence doc comments are the house style. | Scripts, `.swift-format` |
| 2026-10-11 | 2.2 | Which codes the Swift `Code` enum holds | Only codes this SDK can produce: 42 of the Android 46, plus the iOS-only `SWIZZLE_FAILED` (iOS Lifecycle 1). `CONFIG_FROZEN`, `PROCESS_NAME_UNKNOWN`, `NETWORK_STATE_PERMISSION_MISSING`, `NETWORK_CALLBACK_FAILED` and `LIFECYCLE_UNAVAILABLE` are Android-only and stay in the catalogue with that mark, so the backend list is one list. `IssueCodesTests` checks both directions with the Platform column. The raw values are the wire names; the Swift cases are camelCase. | `docs/issue-codes.md` |
| 2026-10-11 | 2.2 | The "threw" halves of Logging 4b in Swift | A `RubiconLogger` or observer closure cannot throw into the SDK, so `CallbackGuard` exposes `reportLoggerFailure(_:)` and `reportObserverFailure(_:)` for the Objective-C wrapper, which catches `NSException` around its blocks and reports; the guard then switches once and logs `LOGGER_THREW` or `OBSERVER_THREW` once. The re-entrancy half runs in Swift through `Thread.current.threadDictionary`. Catching `NSException` needs Objective-C source, and a SwiftPM target cannot mix Swift and Objective-C: step 7.7 will need a small C-family support target or a different catching mechanism; to be raised there. | iOS Logging 2 (as decided), step 7.7 note |
| 2026-10-11 | 2.2 | Log call shape | `log.debug { }`, `log.warn(.code, error, repeatKey:) { }`: a trailing closure, not an autoclosure, so a message that costs something is visibly deferred and the source-rules scanner can treat the closure as part of the call (`check-source-rules.sh` now includes a trailing `{ }` block in the log-call scope). Messages of WARN and ERROR start with the code's raw value. | Root `CLAUDE.md` Code style (already in that form) |
| 2026-10-11 | 2.2 | `Platform.logger` | Added as on Android: the platform's default sink (no-op in the core, `os.Logger` in `Rubicon`) and the fallback of a failed logger; `TransportSettings` carries the instance's `Log`. | - |
| 2026-10-11 | 2.3 | ISO formatter: Foundation diverges before 1582 | The Android vectors caught it on the first run: `ISO8601DateFormatter` (and `Calendar(.gregorian)`) switch to the Julian calendar before 1582-10-15 and write `0001-01-03T00:00:00.000Z` for `0000-01-01`, so the fallback named on iOS Serialization 3 applies: `IsoDates` is the port of the Android calendar arithmetic (proleptic Gregorian, locale-free, thread-safe), not the Foundation formatter. The range rule and the vectors are unchanged; the random comparison against `Calendar` runs from 1583 on and the day arithmetic round-trips over the whole range. Approved by the user on 2026-10-12 and written into iOS Serialization decision 3 (version 2). | iOS Serialization 3 (version 2) |
| 2026-10-11 | 2.3 | Random draws of the id generator | `RandomSource` has one method, `nextUInt64()`; the counter seed takes the low bits of one draw and the tail the low 32 bits of another, in the Android order (seed first, tail second). Kotlin's `Random` sequence is not reproduced; the Android tests are property tests and port unchanged, and `ScriptedRandom` gives known ids for an exact vector. | - |
| 2026-10-11 | 2.3 | HTTP dates | `HttpDates.parse` is the Android parser over the same `daysFromCivil`, including the obsolete-form, day-name and leap-second rules of Android log 2.3; `Hashing.sha256Hex` uses `CryptoKit`. | - |
| 2026-10-11 | 2.4 | `Json.write` on a non-finite double | Throws `JsonError.notFinite(path:)` naming the path, the Swift form of Android's `IllegalArgumentException`: the normalizer never produces one, so a throw there is a caller bug, and the serializer will treat it as such. | - |
| 2026-10-11 | 2.4 | What `JSONSerialization` accepts and writes | Confirmed by the pinned tests on this Foundation: top-level fragments (`12`, `"text"`, `null`) and trailing content after an object are rejected without options, so the Android "trailing content is corrupt" rule needs no extra check; integers read back as `NSNumber` with an integral `objCType` and `50` written from `50.0` reads back as `.int(50)`; `1.5e-7` is written as `1.4999999999999999e-07`. `PropertyValue` is defined in this step, since the writer takes it; the normalizer that produces it is 2.5. | - |
| 2026-10-11 | 2.5 | `developerError` in practice | `Log.developerError(_:)` calls an injected handler, `assertionFailure` by default: a debug build traps, a release build returns, and the caller then logs the problem exactly as with `debug` off, so nothing is ever silent (Android threw instead). Tests inject a recording handler through `TestPlatform.log()`, so the debug path is testable without ending the process. | iOS Configuration 2 (as decided) |
| 2026-10-11 | 2.5 | What a "character" is in the limits | UTF-16 code units, as Kotlin's `length`: 255 for names and keys, 1024 for strings, truncation never inside a surrogate pair. Swift's `count` (grapheme clusters) would make the two SDKs cut the same string at different places. | Root `CLAUDE.md` Public API (limits) |
| 2026-10-11 | 2.5 | Swift details found while porting | An `@objc` enum passed from Swift is a Swift value, not an `NSNumber`, and describes itself as `Type(rawValue: n)`; it is sent as its raw value, the outcome the page documents for the Objective-C path. `Float.nan` bridges to a double `NSNumber`, so its type is reported as `Double`. A Swift dictionary is unordered, so which properties survive the 256 limit is arbitrary, as with a `HashMap`. Depth 4 containers and self-referencing `NSMutableDictionary` or `NSMutableArray` values are dropped with `tooDeep`. | - |
| 2026-10-12 | 3.1 | `beforeSend` and `logging.eventObserver` | Added in 3.2 with `BeforeSend`, `Event` and `EventObserver`, as on Android (log row 3.1); adding a `var` with a default to a struct is compatible. | Steps 3.1 and 3.2 |
| 2026-10-12 | 3.1 | Host validation through `URLComponents` | `URL(string:)` accepts most of the Android reject list (iOS Configuration 3), so `Hosts.normalize` checks `URLComponents`: scheme `http` or `https` in any case, a non-empty host, no query, fragment, user or password, no surrounding whitespace, trailing slashes removed, the text otherwise kept as given (`HTTPS://` stays uppercase, as on Android). The snapshot carries the parsed `URL` next to the text. | - |
| 2026-10-12 | 3.1 | Testing both `debug` defaults | `defaultDebug` is a `#if DEBUG` constant, so one test build sees one value; the nightly workflow gains `swift test -c release -Xswiftc -enable-testing`, which runs the whole suite with the release default and the optimizer on (also the closest the tests get to a Release build's `assertionFailure` being a no-op). | `nightly.yml` |
| 2026-10-12 | 3.2 | Golden files and the two Android-only context fields | The golden files stay the Android ones verbatim (Serialization 5). iOS never writes `context.os.api_level` or `context.network.carrier` (iOS Context 1), so the test's structural comparison removes those two keys from the file before comparing, and nothing else; the sample events carry the file's other values (`Android`, `Pixel 8`, `rubicon-android`) as test data. | `SampleEvents.removingAndroidOnlyFields` |
| 2026-10-12 | 3.2 | Where the hook-result rule lives | `HookRules.check(_:against:)` in the core, next to the types: `nil` only for app events, own kind (a foreign `Event` conformance is `otherKind`), fixed fields equal, automatic events keep name and top-level keys, names valid. The pipeline (6.3a) maps a violation to `before_send` and `HOOK_VIOLATION`. | Step 6.3a |
| 2026-10-12 | 3.2 | `EventUpdate` is not `Equatable` | It carries `any Event`; tests compare its `description` or pattern-match. `TrackEvent`, `ScreenEvent`, `IdentifyEvent` and the context structs are `Equatable` for the tests and the hook rule. | - |
| 2026-10-12 | 3.3 | Default arguments on a protocol | Swift protocol requirements take no defaults, so `track(_:)`, `screen(_:)`, `identify(_:)` and `trackDeepLink(_:)` are overloads in a protocol extension that forward to the requirements; a fake implements only the fourteen requirements. `register(_:value:)` takes `Any`, with `NSNull` for `null`, as iOS Public API 7 lists it. The two `trackDeepLink` methods are protocol requirements (iOS Lifecycle 3), so a fake must implement them too. | - |
| 2026-10-12 | 4.1 | The locked state in the stores | `KeyValueRead` has `missing`, `unreadable`, `locked` and `present`; `KeyValueWrite` has `done`, `locked` and `failed`. A `StoreFile` met by `locked` on load stays unloaded with a DEBUG line (no WARN, no count, no temporary id) and `load()` returns `false` for the writer to call again on `protectedDataDidBecomeAvailable`; a locked write keeps the value dirty with a DEBUG line and no `STORAGE_WRITE_FAILED`. The stores' `state` is optional and `nil` until loaded. Decided by the user on 2026-10-12: before the first unlock `Analytics.deviceId` is `""` (the no-op value) and `isOptedOut` answers from `defaultConsent`, the real values once the writer loads; written into iOS Disk Persistence decision 1. | iOS Disk 1 (version 2); the getters in 6.7 |
| 2026-10-12 | 4.1 | Shapes carried over, with iOS types | `device.json`, `person.json` and `remote-config.json` keep the Android keys and the Android rules for unreadable files (Android log 4.1); `last_failure` may be `cancelled` (iOS Retry 2). In memory the wall-clock fields are `Date` (iOS Event Model 2), written as epoch milliseconds; counters saturate at `Int32.max`, the Android `Int.MAX_VALUE`, so the two files agree. Files are created with mode `0600`; the backup exclusion is set on the first write of the root directory. | - |
| 2026-10-12 | 4.2 | The event store needs no file metadata at all | The port keeps the Android rules (names carry the index, the writer counts what it wrote, a leftover `.tmp` is closed at startup after a byte scan), so neither a timestamp nor a size is ever read: the "one startup size read under `C617.1`" of iOS Disk 3 is unnecessary, and the `lseek` question of 2.1 is moot for the core. `C617.1` is then needed for install detection only (iOS Lifecycle 4). Approved by the user on 2026-10-12 and written into iOS Disk Persistence decision 3 and the iOS Privacy Controls manifest row (both version 2); the 2.1 question on `lseek` is closed with it. | iOS Disk 3, iOS Privacy 1 (version 2) |
| 2026-10-12 | 4.2 | The locked device in the event store | `append` returns `.locked` on a permission error (nothing counted, nothing logged above DEBUG), `writeBatch` returns `.locked` (nothing read, deleted or counted), `closeOpenSegment` keeps the segment open, `open` returns `false` for the writer to call again, and `suspend()` syncs and closes the open segment's handle before the lock without closing the segment; the next `append` reopens the same `.tmp` with its counts intact. The uploader and writer act on these in 6.3b and 6.4. | iOS Disk 1 (as decided) |
| 2026-10-12 | 4.2 | Bodies in memory | `writeBatch` returns the body as `Data` (at most 512 KB plus the envelope) instead of streaming into an output stream, since the transport compresses it in memory in one pass (iOS HTTP 2); a segment is read as bytes and split at line breaks, never held as a `String`. `PosixFileSystem.delete` removes an empty directory with `rmdir`, and `list` of a plain file is empty, as `File.listFiles()` was. | - |
| 2026-10-12 | 5.3, PR #2 | The macOS deployment target of the host build | `Package.swift` declared only `.iOS(.v15)`, so the macOS build that `swift test` and the symbol-graph scripts use took the toolchain's default: macOS 14 on Xcode 27 locally, macOS 10.13 on Xcode 26.6 in CI, where CryptoKit's `SHA256` and `HTTPURLResponse.value(forHTTPHeaderField:)` (both 10.15) failed the `check` lane and the `check-docs.sh --build` step. `.macOS(.v12)` is now declared next to iOS: not a supported platform (iOS Public API 8 stands, nothing is tested or shipped for macOS), only the deployment target of the host build, chosen as the OS generation of iOS 15 so that the macOS build remains a faithful proxy for what the core may call and local and CI agree. | Package.swift; CI |
| 2026-10-12 | 7.2 | `PathNetworkMonitor` | One `NWPathMonitor` on its own serial queue, started once by the writer, never cancelled; `Reading.of(status:interfaces:)` is the pure mapping (`wifi` before `cellular` before `ethernet` among `availableInterfaces`, `nil` when offline), tested without a path object since `NWPath` cannot be built in a test. A first path that is connected changes nothing, because the monitor is optimistic before it (iOS Retry 1); listeners hear connectivity changes, not type changes, and the context reads `networkType` from the monitor's cache at call time (7.3). | `PathNetworkMonitor` |
| 2026-10-12 | 7.2 | Two findings of the simulator lane | On a failing test `xcodebuild test` ran `simctl diagnose` for ten minutes before reporting; `test-simulator.sh` now passes `-collect-test-diagnostics never`. The macOS coverage export of `swift test` holds `RubiconCore` and `RubiconTesting` only, not `Rubicon`, although `RubiconTests` runs there, so the 80 percent gate of D9 cannot be measured on macOS; step 8.1 measures it from the simulator run's result bundle (`xccov`). | `test-simulator.sh`; step 8.1 |
| 2026-10-12 | 7.1 | The protected-data flag at startup is advisory | On the simulator the xctest host reports `UIApplication.shared.isProtectedDataAvailable == false` and never posts `protectedDataDidBecomeAvailableNotification`; a writer that locked itself on the flag therefore never opened, and the first simulator run failed intermittently depending on whether the writer or the main-thread registration ran first. The writer now always tries `loadAndOpen()` at startup and lets a permission error from the stores decide the locked state, which is what iOS Disk 1 defines as "locked" anyway; the flag is still read on the main thread and logged at DEBUG. The iOS Disk Persistence page's sentence "passed to the writer as the initial state" should say "advisory" (a wording change for the user to approve). | `Writer.startUp`, `ApplicationLifecycleSource` |
| 2026-10-12 | 7.1 | `RubiconAnalytics.make` and the iOS platform | `public enum RubiconAnalytics` with `make(configuration:)` and `version`; the `package` overload takes the bundle and the storage root for tests. `IOSPlatform.make` builds `Platform` from `SystemClock`, `UptimeClock` (`systemUptime`, under `Platform/`, reason `35F9.1`), `SystemRandom`, `GCDScheduler`, `URLSessionTransport.factory`, `PosixFileSystem`, the storage root `Application Support/rubicon/` from Foundation's directory list without a file system call, and stand-ins until 7.2 and 7.3 (always connected, no context values), as Android did in its 7.1. `IOSProcessFacts` reads the OS version from `ProcessInfo` (`17.5.1`, or `17.5` for a zero patch, the `UIDevice.systemVersion` form) so the core's transport needs no UIKit; its `installedApp()` carries no dates until 7.4. The factory's own log before the instance exists goes to the sink, as `factoryLog` does on Android. | `RubiconAnalytics`, `IOSPlatform`, `IOSProcessFacts` |
| 2026-10-12 | 7.1 | The sink and errors | `OSLogSink` logs `privacy: .public` as decided; an error passed with a line is written as `[domain code]`, never its description, because a `URLError` description carries the URL and the content rule forbids it (Logging 4a). `warn` maps to `OSLogType.default`, which is unified logging's notice level. The sink has an output seam for the mapping test. | `OSLogSink` |
| 2026-10-12 | 6.7 | `DefaultAnalytics` and `RubiconCore` port notes | `RubiconCore.create(configuration:platform:onCreated:)` builds the core from `Platform` (the stores from `storageRoot` and `fileSystem`, the transport from `transportFactory`), wires the writer to the uploader through `onReady` and `onUploadSignal`, and keeps the process-wide instance in a `Locked`; a second call is a developer error with `debug` on and returns the first (iOS Public API 4). The configuration is a value, so Android's freeze and `CONFIG_FROZEN` have no counterpart. Android's `entry { catch Throwable }` has none either: Swift has no exceptions at the entry points, and a trap in a hook is the hook's own (iOS Public API 6). `Platform` gains `developerError`, the seam `TestPlatform` and the integration tests use to record developer errors instead of trapping (iOS Configuration 2). The two `trackDeepLink` methods of the public protocol are implemented here over `DeepLink.properties` in the core, since URL parsing has no UIKit in it; 7.5 keeps the screens. `shutdown()` stops the writer, the uploader and the transport and waits until both are idle; `flushBlocking` polls by count, since the core reads no clock of its own. | `RubiconCore`, `DefaultAnalytics`, `DeepLink`, `Platform.developerError` |
| 2026-10-12 | 6.7 | `debug` in the integration tests | `AnalyticsConfiguration.debug` defaults to `true` in a debug build (iOS Configuration 2), so the ported `CoreIntegrationTest`, written for Android's `false` default, recorded a developer error from the "release" instance too. `IntegrationSupport.config` sets `debug = false` as the base and the tests that want it say so; the SDK's default is unchanged. | `IntegrationSupport` |
| 2026-10-12 | 6.7 | The stress suite is nightly | The port of the Android `StressTest` (16 threads, 5000 mixed calls each, over the real core and `TestHTTPServer`) takes about a minute on this machine, most of it one-connection-at-a-time HTTP over loopback, which would double the pull request lane. It is gated by `RUBICON_STRESS=1` (`.enabled(if:)`), runs in the nightly TSan job with that variable, and on demand locally. The first local TSan run is recorded in the next row. | `CoreIntegrationTests.stress`, `nightly.yml` |
| 2026-10-12 | 6.7 | The first TSan run | `RUBICON_STRESS=1 swift test --sanitize=thread --filter CoreIntegrationTests` on Xcode 27: the fifteen integration tests and the stress test (16 threads, 5000 calls each, 64 seconds under TSan) passed with no ThreadSanitizer report. The nightly job repeats it on Xcode 26.6. | `CoreIntegrationTests` |
| 2026-10-12 | 6.4 | `Uploader` port notes | The coroutine loop becomes wakes on the uploader queue: `signal()` sets a flag and dispatches a drain, a drain sends until nothing is left, a gate closes or a failure starts a wait, and a wait is a cancellable `schedule(after:)` item that signals again; any wake during a wait cancels and re-checks it (Android log 6.4). The writer tells the uploader twice: `onUploadSignal` on every flush and `onReady` once the stores are loaded, so a process started before the first unlock starts its uploader at the unlock. `HttpTransport` gains `cancelCurrent()` for the background expiration (iOS Queue 2); `beginBackgroundFlush(onDone:)` runs `onDone` when the drain that follows ends, whatever ended it, or at once when the uploader cannot run yet. A cancelled upload (`RetryGroup.interrupted`, iOS Retry 2) ends the drain instead of trying the same batch again while the process is being suspended; the next trigger sends at once, pinned by `UploaderTests.expiration`. `TestScheduler.elapsedClock` reads the virtual time, the counterpart of the Android test's `ElapsedClock { testScheduler.currentTime }`. | `Uploader`, `HttpTransport.cancelCurrent`, `Writer.onReady` |
| 2026-10-12 | 6.3b | `Writer` port notes | The channel is a lock-guarded array with `sent` and `handled` counters; each accepted message dispatches a `drain` to the writer queue of the `Scheduler`, and a drain handles every message waiting, in order (iOS Queue 1). Three iOS additions: while protected data is unavailable `takeNext` hands out only the unlock message, wherever it waits, so events keep their order behind the lock; the two protected-data messages bypass the channel capacity, since the unlock must reach a writer holding a thousand events; a process that starts locked registers its listeners and retries `loadAndOpen` at the unlock, which then opens the foreground if the app is visible. A missing `device.json` under lock is still recognised as missing (metadata is readable), so `readEarly` mints the id in memory and the writer writes it at the unlock; only a file that exists and cannot be read gives `""` (iOS Disk 1), both pinned by `WriterLockedTests`. Android's `guarded` has no counterpart: Swift errors are not exceptions, and a trap is never caught (root rules); `WORKER_FAILED` is logged where the pipeline detects an SDK bug. `AppLifecycle` lives in the core as on Android, with `InstallRule.bundleDates` (60 seconds) and the `libraryDateOnly` fallback selectable at construction, so step 7.4 can switch without touching the core. `InMemoryEventStore` joins `RubiconTesting` with `locked`, `failAppends`, `syncCount` and `suspendCount`. | `Writer`, `AppLifecycle`, `InMemoryEventStore`, `WriterHarness` |
| 2026-10-12 | 6.5, 6.6, 6.3b | Order of the three steps | The Android `Writer` in its final form depends on `ConsentController` (6.5), `Diagnostics` (6.6) and `AppLifecycle` (the core half of 7.4, Android log 7.4), so the two small components are ported before the writer rather than the writer twice: 6.5 ports the controller with its own unit tests, 6.6 the event with the golden comparison, and 6.3b ports the writer with `AppLifecycle` and the harness, where the Android `PrivacyTest`, the `in the writer` half of `DiagnosticsTest` and `AppLifecycleTest` are ported too. The platform half of 7.4 (notifications, the background task, the file dates) stays in 7.4. | Steps 6.5, 6.6, 6.3b |
| 2026-10-12 | 6.5 | `isOptedOut` before the first unlock | `ConsentController.isOptedOut` reads `device.json` early as on Android, but when the device is locked the read cannot happen: it then answers from `defaultConsent` without marking the controller loaded, so the stored choice is still read by the writer's `load()` after the unlock and `optIn`/`optOut` calls made meanwhile apply then, in order (iOS Disk 1). Marking it loaded from a failed early read would have made a stored opt-out invisible for the whole process. | `ConsentController`, `ConsentControllerTests` |
| 2026-10-12 | 6.3a | `EventPipeline` port notes | Ported one to one with three Swift differences. A hook cannot throw (iOS Public API 6), so the Android tests `a throwing hook drops the event` and `a throwing hook rethrows in debug` have no counterpart and `HOOK_THREW` stays reserved for the Objective-C wrapper (7.7). The second validation runs `PropertyNormalizer.normalize(values:)`, a new entry point that turns `PropertyValue` back into Foundation values and applies the same rules, so a hook's NaN, blank key or 2000-character string is handled exactly like a public call's. An unfilled `IdentityRef` (an SDK bug; Android traps with `checkNotNull`) logs `WORKER_FAILED` and drops the event as `storage_error` instead of crashing the host; a test pins it. `library.name` is `rubicon-ios` with `SDKVersion.current`; the golden comparison replaces the library group of the Android file. Hook violations after the first are logged at DEBUG (Logging 2), so the ported tests count the code at any level. | `EventPipeline`, `PropertyNormalizer.normalize(values:)` |
| 2026-10-12 | 6.2 | The heartbeat after a restart | The Android `SessionManager` starts `lastWrittenElapsed` at `Long.MIN_VALUE`; for a session continued from a previous process the first foreground event computes `nowElapsed - MIN_VALUE`, which overflows and wraps negative in Kotlin, so the 30-second last-activity write never happens in that process (only the backgrounding write does). Swift traps on overflow, so the port keeps `lastWrittenElapsed` optional: `nil` means not written in this process and the first foreground event writes, which is what Session 6 says ("at most every 30 seconds"). A test pins it (`a session continued after a restart writes its heartbeat again in the foreground`). The Android behaviour is a bug to report, not a contract. | `SessionManager`; Android `SessionManager.kt:74` |
| 2026-10-12 | 6.1 | `Identity` port notes | The Android `Identity` is ported one to one (`IdentitySnapshot`, `IdentityRef`, `IdentifyTicket`, calls before load replayed in order). Three Swift details: the lock is `NSRecursiveLock`, because `synchronized` is reentrant on Android and `onPersonCleared` may call back into the identity; the user id limit counts UTF-16 units, as every limit does (iOS Serialization 2), so 128 emoji are rejected; with `debug` on an invalid id is a `developerError` followed by the WARN, the pattern of `PropertyProblem.report`, since `assertionFailure` returns in a release build. `register` takes `Any` and reads `NSNull` and an empty optional as `null`. `deviceId` returns `""` while the device is locked before the first unlock (iOS Disk 1). | `Identity`, `IdentityTests` |
| 2026-10-12 | 6.1-8.5 | Working agreement for the rest of the SDK | After PR #2 merged, the user chose to continue as before: steps 6.1 to 8.5 on one branch, `feature/sdk-complete`, one commit per step without a review stop, decisions still asked when missing, one push and one pull request at the end (no intermediate CI runs; the Xcode 26.6 differences surface at that point). Step 8.6 stays out because the `v0.1.0` tag belongs on `master` after the merge, and phase 9 stays out because it lives in `rubicon-team/rubicon-ios-demo`, which does not exist yet; both follow the pull request. | section 2 |
| 2026-10-12 | PR #2 | The API record and closure parameter labels | The second CI run failed the `public API record` step: Xcode 27 spells the unlabeled parameter names of a closure typealias in the symbol graph (`@Sendable (_ level: LogLevel, ...)`), Xcode 26.6 does not. Such names are not callable API, so `api-diff.sh` drops the `_ name:` labels on `swift.typealias` lines before comparing, and `API/RubiconCore.txt` reads the same under both toolchains. Function parameter names stay in the record: both toolchains write them. | Scripts/api-diff.sh |
| 2026-10-12 | 5.1 | What the transport tests cannot reach on macOS | A TLS handshake failure and an App Transport Security refusal need a TLS server with a bad certificate or an iOS app: `TestHTTPServer` speaks plain HTTP. The `URLError` to `FailureKind` table is tested as a pure function for every code, including the certificate codes and -1022; the live `tls` path is left to the consumer apps and the demo (8.1, 9.3). | Step 8.1 |
| 2026-10-12 | 5.1 | Transport details | `Content-Length` is set on the request explicitly (URLSession sets it from the upload data as well); the completion wait is bounded by the resource timeout plus thirty seconds as a guard against a stuck stack; `cancelCurrent()` cancels the task in flight from any thread for the background expiration (iOS Queue 2); the delegate that refuses redirects is a separate object so the transport stays a plain `Sendable` class; `HostResolver` uses `getaddrinfo` and `getnameinfo` with `NI_NUMERICHOST`. | - |
| 2026-10-12 | 5.2 | The one extra line of the retry `switch` | `RetryGroup.interrupted` for `FailureKind.cancelled` (iOS Retry 2): `onResult` clears any wait and records `last_failure = "cancelled"` with no step, no pause and no attempt counted; the next trigger tries at once. Everything else is the Android policy with the same table, jitter, poison-batch and clock-guard rules, over `RandomSource.nextDouble(in:)`. | - |
| 2026-10-12 | 5.2 | Who logs `TLS_FAILED` on iOS | The transport (5.1), where the ATS case needs its own message; the policy logs the four upload codes only, so the code still fires once per process. On Android the policy logged it. | `docs/issue-codes.md` unchanged |
| 2026-10-12 | 5.3 | Remote configuration on iOS | The Android contract and rules unchanged (`docs/remote-config.md` copied with the iOS User-Agent): `RemoteConfig.from` over `[String: PropertyValue]`, `RemoteConfigClient` with `startup()` and the once-per-launch `fetch()`, `Sampling` over the same salted SHA-256 buckets, `RuntimeFlags` as two atomic off-switches. `startup()` before the device store is loaded (a locked device) samples with an empty id; the core factory (6.7) calls it only after the stores load. | `docs/remote-config.md` |
| 2026-10-11 | 1.2 | Where the property rules live | As on Android (log row 1.2): property validation, the conversion table, the limits and the `beforeSend` rules are in the root `CLAUDE.md` under Public API; the core file points there. | - |

## 16. Out of scope for the first release

Recorded on the Confluence pages as rejected or deferred; not implemented until decided: actors as
the workers (revisited at iOS 17, iOS Queue 1), a binary or CocoaPods distribution (iOS Public API 8),
an SDK-forced protection class (`storage.protection`, iOS Disk 1), a writer of our own for Android
number text parity (iOS Serialization 1), a `requestFactory` or `URLSessionConfiguration` hook and an
SDK pinning API (iOS HTTP 4), a Low Data Mode rule (iOS Retry 1), a log category per area and a
runtime log level setter (iOS Logging 1), macOS, tvOS, watchOS and visionOS. The Android list applies
as well: wrapper SDK boundaries (React Native, Flutter), SDK lifecycle states and `shutdown()`,
performance and reliability budgets, the versioned backend contract document and deduplication
window, a diagnostic API beyond `SDK Diagnostics`, typed property overloads, `group`.
