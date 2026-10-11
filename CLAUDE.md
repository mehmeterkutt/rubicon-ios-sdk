# Rubicon iOS SDK

Analytics SDK for iOS in Swift. This file and each target's `CLAUDE.md` (written in step 1.2) are the
contract for how code is written here; read them before changing anything.

- The design is decided in Confluence (space SD; Atlassian MCP, `cloudId` `rubiconn.atlassian.net`)
  and is binding. The iOS entry page is "Analytics SDK: iOS" (id 8192025) with fourteen `iOS: <block>`
  child pages; each inherits the Android decision page of the same block, and only what differs on
  iOS is written on the iOS page. A pointer such as (Queue 4) means decision 4 on the Android Queue
  with Flush Policy page; (iOS Queue 2) means decision 2 on the iOS page. Page ids are in section 1
  of `docs/implementation-plan.md`. The reasoning lives there, not here.
- Work follows `docs/implementation-plan.md`: read its "Working agreement" and "Status" at the start
  of every session and take the first unchecked step.
- Never decide something the decisions do not cover: stop and ask, with options and a recommendation.
- The Android SDK (`~/Projects/rubicon-android-sdk`) is the reference implementation of the same
  contract: its `sdk-core/CLAUDE.md` rules, golden wire files (`sdk-core/src/test/resources/golden/`),
  `docs/issue-codes.md` and implementation decisions log apply here unless an iOS page says otherwise.
  Where Android code and an iOS decision disagree, the iOS decision wins.

## Targets

| Target | Role |
|---|---|
| `RubiconCore` | Foundation only, no UIKit: configuration, pipeline, queue, storage, identity, sessions, upload, HTTP, retry. Tested with `swift test` on macOS. |
| `Rubicon` | iOS: the factory `RubiconAnalytics.make`, platform implementations, UIKit lifecycle, screens, deep links, `RubiconNetworkObserver`, the privacy manifest. Tested on the simulator. |
| `RubiconObjC` | The Objective-C wrapper (`RBN` prefix), a separate product depending on `Rubicon`. |
| `RubiconTesting` | Test support shared by the test targets: `TestPlatform` fakes, the virtual-time scheduler, the test HTTP server. Never a product. |

Rules per target are written in step 1.2 (`Sources/<Target>/CLAUDE.md`). Until then the Android
`sdk-core/CLAUDE.md` and `sdk-android/CLAUDE.md` are read for the rules, with the iOS pages for the
differences.

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
swift test --sanitize=thread  # Thread Sanitizer on the core tests (nightly in CI)
```

Local toolchain is Xcode 27 (Swift 6.4); the release toolchain is Xcode 26.6 on the `macos-26`
runner, the last that builds for the iOS 15 floor. CI is the gate: a build that passes locally and
fails there is fixed, not waved through. Keep the sources inside `swift-tools-version` 6.0.

## Non-negotiables

Inherited from the Android root `CLAUDE.md` unchanged: never crash the host app, public API is
forever, everything internal unless it must be public, no new dependencies, documentation on every
public symbol, a diff that defines a public API change. iOS additions: no `print`; no `#available`
checks (iOS 15 is the floor, iOS Public API 2); no required-reason API outside the two declared
categories (iOS Privacy 1); no UIKit import outside `Rubicon`; Swift 6 language mode in every target.

## Git and pull requests

- `master` holds releases, `develop` the next one. One plan phase is one `feature/<topic>` branch
  from `develop` and one pull request; each step in it is one commit, reviewed by the user before it
  is made. Conventional Commits (`feat(queue): ...`, `build: ...`). Squash merge into `develop`.
- Before committing: `Scripts/format.sh`, then `Scripts/check.sh` green.
- Stop for review with the changes uncommitted; commit, push and open the pull request only after
  the user approves. Never merge, never push to `develop` or `master`.
- The description follows `.github/pull_request_template.md`.
