# The privacy manifest

What `Sources/Rubicon/PrivacyInfo.xcprivacy` declares and why, for the privacy and App Review work of
the apps that ship the SDK. The decision is iOS Privacy Controls 1; the identifiers and the reason
texts were checked against Apple's documentation on 2026-10-12.

The `Rubicon` target ships the one manifest, because its platform code is the only code that
collects data and calls a required-reason API. `RubiconCore` defines protocols and the pipeline;
`RubiconObjC` forwards calls. Xcode aggregates the manifest into the app's privacy report, from which
the app's privacy label is filled in.

## Tracking

`NSPrivacyTracking` is `false` and `NSPrivacyTrackingDomains` is empty. The SDK never combines the
app's data with data from other companies, never reads the advertising identifier, never calls App
Tracking Transparency and shares nothing with data brokers. There is no way for the app to hand the
SDK an advertising identifier.

## Collected data types

Each entry says what the SDK can collect once it is integrated, whether or not a given app uses the
feature. Every type is marked "not used for tracking".

| Data type | Linked to the user | Purpose | What produces it |
| --- | --- | --- | --- |
| Device ID | yes | Analytics | `device_id`, the installation's random identifier, on every event. Apple's "other device-level ID". It is linked because `identify` can tie it to an account. |
| User ID | yes | Analytics | `identify(userId)` and the `user_id` field of every later event. |
| Product Interaction | yes | Analytics | `track`, `screen`, the automatic lifecycle events, screen views and deep links. |
| Performance Data | yes | Analytics | `Network Request` events (`duration_ms`, byte counts) when `networkRequests` capture is on. |
| Coarse Location | yes | Analytics | The SDK sends no location. The backend derives country and city from the IP address of each upload unless the project's IP anonymisation setting is on; by Apple's rule on IP addresses that is collected location data of the app. |
| Other Diagnostic Data | no | App Functionality | `SDK Diagnostics`: drop and issue counts, carrying no identity beyond the device. |

## Required-reason APIs

| Category | Reason | The calls |
| --- | --- | --- |
| `NSPrivacyAccessedAPICategorySystemBootTime` | `35F9.1`: measuring the time elapsed between events within the app | `ProcessInfo.systemUptime` in `UptimeClock`, the monotonic clock behind session timeouts, the heartbeat and retry backoff. Only elapsed times leave the device, which the reason permits. |
| `NSPrivacyAccessedAPICategoryFileTimestamp` | `C617.1`: timestamps of files inside the app container | The creation dates of the app's `Library` directory and of the app bundle in `IOSProcessFacts`, read once at startup to tell an install from an update. The event store reads no file metadata. |

Nothing else: no `UserDefaults` (identity and consent live in files under `Application Support`),
no disk space API, no active keyboard API. `Scripts/check-required-reason-apis.sh` greps every
source file of every target for Apple's full symbol list and fails when a symbol of an undeclared
category appears anywhere, or a symbol of a declared category appears outside
`Sources/Rubicon/Platform/`. `PrivacyManifestTests` reads the manifest from the built resource bundle
and pins every key, type, flag and reason.

## Filling in the app's privacy label

What to declare in App Store Connect for the SDK's share of the app:

| SDK feature | Data type on the label | Drop the row when |
| --- | --- | --- |
| Any upload | Device ID | never |
| Any upload | Coarse Location | the project's IP anonymisation setting is on |
| `identify` | User ID | the app never calls `identify` |
| `track`, `screen`, `appLifecycle`, `installUpdate`, `sessions`, `screenViews`, `deepLinks` | Product Interaction | never in practice: the lifecycle events alone count |
| `networkRequests` | Performance Data | `networkRequests` is disabled in the configuration |
| `sendDiagnostics` | Other Diagnostic Data | `sendDiagnostics` is `false` |

Every type the SDK collects is "linked to you" once the app calls `identify`, since the device id
then belongs to an account; Other Diagnostic Data is not linked. No type is "used to track you".
Disabling an automatic capture feature or a context field changes what leaves the device; this table
and the manifest change with the SDK, not with the app's configuration, so an app that switches a
feature off may remove that row from its own label.
