# Wire format

What the iOS SDK sends to `{host}/v1/batch`: the contract with the backend, the same contract the
Android SDK implements. The golden files in `Tests/RubiconCoreTests/Fixtures/golden/` are copies of
the Android files (`Scripts/refresh-golden.sh`), the normative examples; the tests compare what the
SDK writes with them structurally and parse each one with an independent parser (Serialization 5).
When this page and a golden file disagree, the golden file is right and this page is fixed. The
Android `docs/wire-format.md` describes the shared parts in full; this page lists what iOS sends
and where it differs.

Status: complete for the first release (step 8.4), pending backend review.

## Request

- `POST {host}/v1/batch`, `Content-Type: application/json`, `Authorization: Bearer {apiKey}`.
- The body is gzipped (`Content-Encoding: gzip`), or sent uncompressed if compression failed; it
  has a fixed length, never chunked.
- `User-Agent: rubicon-ios/{version} (iOS {os})`, for example `rubicon-ios/0.1.0 (iOS 17.5.1)`.
- One batch holds at most 100 events and 512 KB before compression, oldest first.
- The server answers 200 for every well-formed batch; a success body is never read. Status codes
  and `Retry-After` are handled as the HTTP and Retry decisions say (`Sources/RubiconCore/CLAUDE.md`).

## Envelope

Golden file: `envelope.json`.

```json
{ "sent_at": 1759147260000, "batch": [ { ...event... }, { ...event... } ] }
```

| Key | Type | Meaning |
|---|---|---|
| `sent_at` | number | Epoch milliseconds when this attempt was sent; rewritten on every retry, so the backend can correct device clock skew against `timestamp` |
| `batch` | array | The events, each exactly as stored on the device |

The same event can arrive more than once (at-least-once delivery: a retry after a lost response, a
process killed during an upload, a background task that expired mid-request). It always carries
the same `message_id`; the backend deduplicates on it.

## Event

| Key | Type | Present | Meaning |
|---|---|---|---|
| `type` | string | always | `track`, `screen` or `identify` |
| `event` | string | `track` | The event name, 1 to 255 characters |
| `name` | string | `screen` | The screen name, 1 to 255 characters |
| `source` | string | always | `app` for the developer's calls, `auto` for what the SDK captures; new values may come in minor versions |
| `message_id` | string | always | UUIDv7, unique per event, never regenerated |
| `timestamp` | number | always | Epoch milliseconds on the device when the event was created |
| `user_id` | string or null | always | The identified user; `null` while anonymous |
| `device_id` | string | always | UUIDv7 of this installation; renewed by `clearLocalData()` |
| `properties` | object | `track`, `screen` | The developer's or the SDK's properties; may be empty |
| `traits` | object | `identify` | The user's traits |
| `context` | object | always | What the SDK measured; below |

Property and trait values are strings, booleans, numbers, `null`, lists and objects of those, at
most three levels deep. `Date` values are strings, `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` in UTC (the
proleptic Gregorian calendar, as on Android; iOS Serialization 3). A string is at most 1024
characters, a line at most 32 KB. Booleans are never confused with numbers: `true` and `1` stay
apart however the value was created (iOS Public API 5).

**Number text.** The iOS SDK writes numbers through `JSONSerialization`, which prints a
non-integral double with seventeen significant digits: the `Double` `49.9` arrives as
`49.899999999999999`, where Android writes `49.9`. Both texts parse to the same IEEE 754 value;
a backend that compares the text, or stores it as a decimal string, must parse it first (iOS
Serialization 1). Integral values (`Int`, and a `Double` with no fraction) are written as integers.

Golden files: `track.json`, `screen.json`, `identify.json`.

## Context

A value the SDK could not read is left out, never sent as `null` or `""`; a group with no value is
left out. The app can switch fields off (`context.disabledFields`); `library` is always sent.

| Key | Type | iOS value |
|---|---|---|
| `app.name`, `app.version`, `app.build`, `app.namespace` | string | `CFBundleDisplayName` or `CFBundleName`, `CFBundleShortVersionString`, `CFBundleVersion`, the bundle identifier |
| `device.manufacturer`, `device.model` | string | `Apple`, the hardware identifier such as `iPhone16,1` (`x86_64` or `arm64` on the simulator) |
| `device.type` | string | `phone` or `tablet` |
| `device.is_emulator` | boolean | `true` on the simulator |
| `os.name`, `os.version` | string | `iOS`, `17.5.1` |
| `screen.width`, `screen.height` | number | The whole display in pixels (`UIScreen.nativeBounds`), the short side as width |
| `screen.density` | number | `UIScreen.scale`, such as `3` |
| `network.type` | string | `wifi`, `cellular`, `ethernet`, `other` or `none`, from `NWPathMonitor` |
| `locale` | string | `tr-TR` (BCP 47), language from the app's preferred localization, region from the device |
| `timezone` | string | `Europe/Istanbul` (IANA) |
| `session.id` | string | UUIDv7; absent outside a session |
| `session.started_at` | number | Epoch milliseconds |
| `library.name`, `library.version` | string | `rubicon-ios`, `0.1.0` |

Not sent by iOS: `os.api_level` and `network.carrier`, which exist only on Android. The golden
files carry them; the iOS tests remove those two keys before comparing.

## Automatic events

All have `source: "auto"`. Each type can be switched off by the app (`autocapture.enabled`) or by
remote configuration. The properties are the Android ones; the golden files are shared.

| Event | Type | Properties | Golden file |
|---|---|---|---|
| `Application Installed` | track | `version`, `build` (string), `installed_at` (date) | `application-installed.json` |
| `Application Updated` | track | `version`, `build`, `previous_version` and `previous_build` when known, `updated_at`, `is_downgrade: true` only when the build went down | `application-updated.json` |
| `Application Opened` | track | `from_background` (boolean) | `application-opened.json` |
| `Application Backgrounded` | track | none | `application-backgrounded.json` |
| `Session Started` | track | none; right before the event that starts the session | `session-started.json` |
| `Session Ended` | track | `duration_ms`; timestamped at the session's last activity, with the ended session in `context.session` | `session-ended.json` |
| Screen view | screen | `name_source`: `annotation` (`ScreenNamed` or `RBNScreenNamed`) or `class` | `screen.json` |
| `Deep Link Opened` | track | `scheme`, `host`, `path`, the `utm_source`, `utm_medium`, `utm_campaign`, `utm_term`, `utm_content` present, `referrer` (the source application's bundle identifier for a URL scheme link, the referrer URL's host for a universal link); never other query parameters or the fragment | `deep-link-opened.json` |
| `Network Request` | track | `method`, `url` and `path` without query or fragment and with ids as `:id`, `host`, `status_code` (absent when the call failed), `error` (`canceled`, `timeout`, `unknown_host`, `connect`, `tls` or the `URLError` code's name), `duration_ms`, `request_bytes` and `response_bytes` when known | `network-request.json` |
| `SDK Diagnostics` | track | `period_start` (date), `dropped` (`total` and a count per reason), `issues` (a count per code of `docs/issue-codes.md`); never through `beforeSend` | `sdk-diagnostics.json` |

A developer may send events with the same names; `source` tells them apart. The backend shows
`source` as a breakdown rather than merging both into one row.

## Keeping the copies true

`Scripts/refresh-golden.sh` copies the Android files and records their digest in
`Fixtures/golden/SOURCE.sha256`; `refresh-golden.sh --check`, run by `check.sh`, fails when the
copies no longer match the recorded digest (a copy was edited by hand) and, when the Android
repository is present on the machine, when its files no longer produce that digest (the contract
changed on Android and the copies were not refreshed). CI has no Android checkout, so the second
half runs on a developer's machine, before a release at the latest (step 8.6).
