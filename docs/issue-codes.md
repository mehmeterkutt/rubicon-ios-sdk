# Issue codes

Every WARN and ERROR line of the SDK carries one of these codes (Logging decisions 1 and 2). A code
is logged at its own level once per process; later occurrences are logged at DEBUG. Every
occurrence is counted, and `SDK Diagnostics` reports the counts in `issues` (Logging decision 5).

The names are part of the backend contract and are shared with the Android SDK, whose catalogue
(`docs/issue-codes.md` in `rubicon-android-sdk`) is the origin of this one. A code is never renamed
or reused; a new situation gets a new code, added to both catalogues in the same pull request as
the log line. The Platform column says where a code can occur: `both`, `Android` (never produced by
this SDK, so not in its `Code` enum) or `iOS`. `IssueCodesTests` fails when this file and `Code`
disagree.

Status: copied from the Android catalogue in step 2.2 with the iOS differences; pending backend
review together with the Android list.

## Logging

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `LOGGER_THREW` | WARN | both | The developer's logger threw; the platform logger is used for the rest of the process. On iOS only the Objective-C wrapper can report it: a Swift closure that traps stops the app. | Logging 4b, iOS Logging 2 |
| `OBSERVER_THREW` | ERROR | both | The developer's `eventObserver` threw; it is switched off for the rest of the process. On iOS only the Objective-C wrapper can report it. | Logging 4b, iOS Logging 2 |
| `WORKER_FAILED` | ERROR | both | An SDK worker failed with an unexpected error; the SDK keeps running. | Queue 1 |

## Configuration

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `INVALID_API_KEY` | ERROR | both | The API key is blank; the factory returns a no-op instance. | Configuration 3 |
| `INVALID_HOST` | ERROR | both | The host is not a valid base URL; the factory returns a no-op instance. | Configuration 3 |
| `CLEARTEXT_HOST` | WARN | both | The host uses `http://`. On iOS the first upload fails with `TLS_FAILED` unless the app declares an ATS exception. | Configuration 3, iOS HTTP 3 |
| `SETTING_OUT_OF_BOUNDS` | WARN | both | A numeric setting was out of bounds and was clamped to the nearest bound. | Configuration 3 |
| `CONTRADICTING_SETTINGS` | WARN | both | Settings of a group contradict each other; the group's defaults are used. | Configuration 3 |
| `CONFIG_FROZEN` | WARN | Android | A setting was written after the SDK was created; the write is ignored. The iOS configuration is a value type, so a late write cannot reach the SDK. | Configuration 4, iOS Configuration 1 |
| `RESERVED_HEADER` | WARN | both | `network.headers` tried to override a reserved header; it is ignored. | Configuration 5 |
| `SECOND_INSTANCE` | ERROR | both | A second instance was created in the process; the first one is returned. | Configuration 3, Public API 1 |
| `PROCESS_NAME_UNKNOWN` | WARN | Android | The process name could not be determined; the main process is assumed. iOS has no process check; an app extension gets a no-op instance with an INFO line. | Disk 2d, iOS Queue 2 |
| `REMOTE_CONFIG_FAILED` | WARN | both | The remote configuration could not be fetched or read; the last valid values, or code, are used. | Configuration 1 |
| `REMOTE_CONFIG_INVALID_VALUE` | WARN | both | A remote configuration value was invalid and is ignored. | Configuration 3 |

## Events and properties

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `PROPERTY_DROPPED` | WARN | both | A property or trait was dropped: unsupported type, NaN or infinity, invalid key or too deep. | Public API 3, Serialization 2, 3 |
| `PROPERTY_TRUNCATED` | WARN | both | A string value was longer than 1024 characters and was truncated. Logged once per key. | Serialization 3 |
| `TOO_MANY_PROPERTIES` | WARN | both | An event had more than 256 properties; the extra ones were dropped, super properties first. | Serialization 3 |
| `INVALID_EVENT_NAME` | WARN | both | An event or screen name was blank or longer than 255 characters; the event was dropped. | Serialization 3 |
| `HOOK_THREW` | ERROR | both | A `beforeSend` hook threw; the event was dropped. On iOS only the Objective-C wrapper can report it. | Public API 4, iOS Public API 6 |
| `HOOK_VIOLATION` | ERROR | both | A `beforeSend` hook returned what its rules do not allow: a renamed automatic event, added or removed top-level keys, `nil` for an automatic event, an invalid name, or an event of another kind or with changed fixed fields; the event was dropped. | Public API 4 |

## Identity

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `INVALID_USER_ID` | WARN | both | `identify` was called with a blank user id or one longer than 255 characters; the call is ignored. | Identity 3 |

## Storage

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `STORE_UNREADABLE` | WARN | both | `device.json`, `person.json` or `remote-config.json` exists but cannot be read; in-memory values are used and the file is left untouched. A locked device is not this state (iOS Disk 1). | Identity 1, Disk 7 |
| `STORAGE_WRITE_FAILED` | ERROR | both | An event or a store could not be written, for example on a full disk. | Disk 4, Logging 2 |
| `CORRUPT_LINE` | ERROR | both | A stored event line was corrupt and was skipped. | Disk 5 |
| `UNREADABLE_SEGMENT` | ERROR | both | A segment could not be read; it is deleted after three consecutive failures. | Disk 5 |
| `UNKNOWN_FILE` | WARN | both | A file in the events directory that does not match the naming scheme was deleted. | Disk 5 |

## Dropped events

Each drop reason without a code of its own above (`CORRUPT_LINE`, `STORAGE_WRITE_FAILED`) or elsewhere
(`HOOK_THREW`) has one here; the event counts per reason are in `dropped` (Queue 5, Logging 5).

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `QUEUE_FULL` | WARN | both | More than 1000 events were pending; the oldest were dropped (`queue_full`). | Queue 5 |
| `EVENTS_EXPIRED` | WARN | both | Events older than 3 days were deleted unsent (`expired`). | Queue 5 |
| `API_KEY_CHANGED` | WARN | both | Events tracked with another API key were deleted at startup (`api_key_changed`). | Disk 2c |
| `BACKPRESSURE` | WARN | both | The write channel was full and an event was dropped (`backpressure`). | Queue 1 |
| `EVENT_OVERSIZE` | WARN | both | A serialized event was larger than 32 KB and was dropped (`oversize`). | Serialization 3 |
| `BATCH_REJECTED` | WARN | both | The server rejected a batch as malformed (400, 422 or another 4xx of group D); it was deleted (`rejected`). | Retry 1 |
| `RETRY_EXHAUSTED` | WARN | both | A batch failed 10 times while other batches were accepted; it was deleted (`retry_exhausted`). | Retry 3 |

## Upload

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `HOST_BLOCKED` | WARN | both | The host resolves to a local address, as ad blockers, private DNS and encrypted-DNS profiles do. | HTTP 6, iOS HTTP 3 |
| `HTTP_REDIRECT` | ERROR | both | The host answered with a redirect; `host` must be set to the final URL. | HTTP 5, Retry 1 |
| `TLS_FAILED` | ERROR | both | The TLS handshake failed, for example on an untrusted certificate; on iOS also an App Transport Security refusal of an `http` host. | HTTP 4, Retry 1, iOS HTTP 3 |
| `HTTP_UNEXPECTED` | ERROR | both | The HTTP stack failed with an unexpected error. | HTTP 4, Retry 1 |
| `UPLOAD_UNAUTHORIZED` | ERROR | both | The server rejected the API key (401, 403). | Retry 1 |
| `UPLOAD_ENDPOINT_MISSING` | ERROR | both | The endpoint does not exist (404, 410); `host` is probably wrong. | Retry 1 |
| `UPLOAD_TOO_LARGE` | ERROR | both | A gateway rejected the request size (413). | Retry 1, 4 |
| `UPLOAD_NOT_SUPPORTED` | ERROR | both | The server does not support the request (501, 505). | Retry 1 |
| `COMPRESSION_FAILED` | WARN | both | Compressing a request failed; it was sent uncompressed. | HTTP 2 |

## Network and lifecycle

| Code | Level | Platform | Meaning | Decision |
|---|---|---|---|---|
| `NETWORK_STATE_PERMISSION_MISSING` | WARN | Android | The app removed `ACCESS_NETWORK_STATE`; connectivity is assumed. iOS has no such permission. | Retry 6, iOS Retry 1 |
| `NETWORK_CALLBACK_FAILED` | WARN | Android | Registering the network callback failed; connectivity is queried before each flush. Starting `NWPathMonitor` cannot fail. | Retry 6, iOS Retry 1 |
| `INVALID_CAPTURE_HOST` | WARN | both | A host pattern of the network interceptor or observer is invalid (a scheme, path, port, or a wildcard other than a leading `*.` followed by two labels); it was ignored. `developerError` when `debug` is on. | Privacy 5c |
| `LIFECYCLE_UNAVAILABLE` | WARN | Android | Neither `ProcessLifecycleOwner` nor the activity counter could observe the app's foreground; no lifecycle events, sessions or background flush. The iOS application notifications always exist. | Lifecycle 2, iOS Session 1 |
| `SWIZZLE_FAILED` | WARN | iOS | The `viewDidAppear` swizzle could not be installed (class or selector not found); automatic screen views are absent. | iOS Lifecycle 1 |
