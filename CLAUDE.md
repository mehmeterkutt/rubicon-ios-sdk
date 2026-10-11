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

Filled in step 1.1 (`Scripts/check.sh` runs format lint, build, tests, API diff, coverage and the
source rules; the individual commands are listed there).

## Non-negotiables

Inherited from the Android root `CLAUDE.md` unchanged: never crash the host app, public API is
forever, everything internal unless it must be public, no new dependencies, documentation on every
public symbol, a diff that defines a public API change. iOS additions: no `print`; no `#available`
checks (iOS 15 is the floor, iOS Public API 2); no required-reason API outside the two declared
categories (iOS Privacy 1); no UIKit import outside `Rubicon`; Swift 6 language mode in every target.
