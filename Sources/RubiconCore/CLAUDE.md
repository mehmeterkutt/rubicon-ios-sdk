# RubiconCore

Foundation only: no UIKit, no `os.Logger`, no `Network`, no `UIApplication`. The platform comes
through the internal `Platform` (clock, elapsed clock, random source, file system, network monitor,
HTTP transport, context provider, process info, lifecycle source, scheduler); tests replace it with
`TestPlatform` from `RubiconTesting` through the `package` factory overload (Configuration 5).
Property validation and `beforeSend` rules are in the root `CLAUDE.md`. Folders follow the Android
packages: `platform`, `log`, `util`, `json`, `validation`, `config`, `event`, `storage`, `queue`,
`http`, `retry`, `identity`, `session`, `context`, `privacy`, `remote`, `diagnostics`, `pipeline`;
public types at the top level of the target.

## Event model

- Top level is the event's identity (Event Model 1): `type`, `event` (track) or `name` (screen),
  `source` (`app`/`auto`, set only by the SDK), `message_id`, `timestamp`, `user_id`, `device_id`.
  `properties` (track, screen) and `traits` (identify) belong to the developer; the SDK never writes
  into them. Super properties merge into `properties`, the event's own key wins. `context` belongs to
  the SDK (`app`, `device`, `os`, `screen`, `network`, `locale`, `timezone`, `session`, `library`)
  and is read-only for hooks (Context 4). Wire keys are `snake_case`.
- `protocol Event: Sendable` with `source`, `messageId`, `timestamp`, `userId`, `deviceId`, `context`
  as get-only requirements; `TrackEvent`, `ScreenEvent`, `IdentifyEvent` structs with those as `let`
  and `name`, `properties` or `traits` as `var`; `enum EventSource: String { case app, auto }`.
  `EventContext` and its groups are `Sendable` structs with `let` fields and internal initializers.
  Kinds may be added in minor versions; the documentation asks hook authors to return unknown kinds
  unchanged. `description`: type, name, message id only (iOS Event Model 1).
- `messageId`: 36 lowercase characters from the Swift port of `UuidV7Generator` with the Android
  layout and counter rules (log row 2.3), its own hexadecimal table, never Foundation `UUID`.
  Created on the calling thread, persisted, never regenerated. The same generator makes `device_id`
  and the session id (iOS Event Model 3).
- Time in memory is `Date` from the injected clock at call time; on the wire `timestamp`, `sent_at`
  and `context.session.started_at` are epoch milliseconds, rounded, converted once in the
  serializer. `Date` in properties becomes `yyyy-MM-dd'T'HH:mm:ss.SSS'Z'` through one shared
  `ISO8601DateFormatter` with fractional seconds; years outside 0000 to 9999 are rejected before
  it; the Android `IsoDates` vectors run against it. `sent_at` is rewritten on every attempt (iOS
  Event Model 2, iOS Serialization 3).

## Configuration

- `AnalyticsConfiguration(apiKey:)`, a `Sendable` struct. Top level: `host` (`defaultHost`, the SaaS
  placeholder, overridable for on-prem; endpoints `{host}/v1/batch`, `{host}/v1/config`), `debug`
  (default `true` under `#if DEBUG`, else `false`), `beforeSend`. Groups as nested structs: `flush`,
  `session`, `autocapture` (`enabled: Set<Autocapture>`), `context`, `privacy`, `logging`, `network`
  (Configuration 2; no `remote` group). About twenty public settings; tuning values (batch and queue
  limits, backoff, retry limits, timeouts, compression) are internal constants; making one public is
  a design discussion.
- No platform types in the core; platform-neutral names (`Autocapture.appLifecycle`); `Rubicon`
  decides the mechanism (Configuration 6).
- The factory validates (Configuration 3). `developerError` in debug. Release: blank key or invalid
  host -> no-op instance and ERROR; out-of-bounds numbers clamped, WARN; contradicting values -> group
  defaults, WARN. `host` is a `String` validated with the Android rules (`http` or `https`, a host
  name, no query, fragment, user info or whitespace, never trimmed, trailing slashes removed; `http`
  warns `CLEARTEXT_HOST`), parsed once into a `URL` in the snapshot; the effective host is logged
  once at INFO (iOS Configuration 3). A second factory call is `developerError` in debug and returns
  the existing instance in release.
- The snapshot is the validated struct; a write to the caller's copy after `make` never reaches the
  SDK, so there is no freezing and no frozen-write diagnostic (iOS Configuration 1). Runtime changes
  only through `Analytics` methods (Configuration 4).
- Remote configuration (Configuration 1): background `GET {host}/v1/config` with ETag; it only
  restricts (`enabled`, autocapture types to switch off, `flush_interval_ms`, `flush_at`,
  `sample_rate`). Saved, applied next launch; `enabled = false` and `networkRequests` off apply at
  once. Failure -> last valid remote values or code. Same validator; an invalid key is ignored with
  WARN.
- `network.headers` never override `Authorization`, `Content-Type`, `Content-Encoding`,
  `Content-Length`, `User-Agent`, `Host`, `If-None-Match` or `X-Rubicon-*`, in any letter case. No IP
  flag or header: that is a backend setting (Privacy 6).

## Identity, super properties and privacy

- `device_id`: UUIDv7 created on first launch. `user_id`: set by `identify`, `nil` = anonymous. No
  identified flag, no alias ever, no group (Identity 1, 6). Missing file: generate and write.
  Unreadable (corrupt, newer `v`): temporary in-memory id, never overwrite, WARN. Locked (iOS Disk 1):
  neither; wait for protected data.
- `identify(_ userId:traits:)` (Identity 3, 4): anonymous -> set and persist, send `IdentifyEvent`;
  same id with traits -> `IdentifyEvent` only; same id without -> nothing; a different id while
  identified -> clear `PersonStore`, then identify, INFO without ids. Blank or over 255 characters ->
  `developerError` in debug, WARN and ignore in release; never trim. Traits are set-only, never stored.
- `PersonStore`: `user_id`, super properties, open session. `DeviceStore`: `device_id`, consent, last
  version and build, remote configuration cache, retry state, drop counters. For a new value ask:
  "if another person logs in on this device, should it carry over?" Yes -> `DeviceStore`, else
  `PersonStore`. A test asserts each store's exact key set. `reset()` clears `PersonStore` only,
  leaves the queue, sends no event, never renews `device_id` (Identity 5).
- Merge is implicit: both ids on every event; two different non-nil `user_id`s never merge
  (Identity 2). `identify`, `reset`, `register`, `unregister` apply synchronously in memory and
  asynchronously to disk, so `identify()` then `track()` sees the new identity. Super properties are
  validated at `register`; `null` is stored and sent (Context 5).
- `privacy.defaultConsent`: `.granted` (default) or `.pending` (write, never upload, until decided);
  `privacy.persistConsent` (default `true`) stores the choice, which beats the default (Privacy 2, 4).
  The writer loads `DeviceStore` before anything, so an opted-out user's startup events never reach
  disk; the factory never reads it on the main thread (only an early `isOptedOut` may, once).
- `optOut()` (Privacy 1): no new events of any kind, the open session ends silently; queued events
  still upload; `identify`, `register`, `reset` change local state without events. `optIn()`:
  resume, no event. From `.pending`, `optOut()` deletes waiting events uncounted, `optIn()` uploads
  them. `clearLocalData()` (write channel): deletes segments, `PersonStore`, drop counters, retry
  state; renews `device_id`; keeps consent, last version and build, remote configuration; no event
  or count (Privacy 3).

## Session state

- Every event carries `context.session.id` (UUIDv7) and `started_at`; changes are announced
  internally (`package`), not publicly (Session 1, 2).
- The foreground keeps a session alive; backgrounding starts the countdown; returning before
  `session.backgroundTimeoutMs` (default 5 min, 10 s to 2 h, not remote) continues it; maximum 12 h
  (internal). No inactivity timeout, no timers: evaluate on foreground, on each event and at process
  start; background time from the `ElapsedClock` (Session 3, 4). Background events use a still-valid
  session but never extend it; after it ends they carry none and never start one. No session until
  the first foreground; the platform only reports foreground and background (log row 7.4).
- `Autocapture.sessions` (on): `Session Started` right before the event that starts a session;
  `Session Ended` on detection, backdated to the last activity, `duration_ms` (the one derived value
  of the elapsed clock that leaves the device, allowed by reason `35F9.1`) (Session 5).
- In `PersonStore` (Session 6): id and `started_at` at start; last activity (wall clock) on
  backgrounding and at most every 30 s in the foreground. Process start: clock moved back -> end;
  within timeout and maximum -> continue; else backdated `Session Ended` and clear.
- `reset()` and a different user: `Session Ended` with the old `user_id` first, then clear
  `PersonStore`; the next foreground event starts a new session with `Session Started`.

## Writer, uploader and flushing

- Two serial `DispatchQueue`s from `Platform` (`com.rubicon.analytics.writer`, `.uploader`,
  `qos: .utility`), never the main queue (iOS Queue 1). **Writer**: hooks, second validation,
  serialization, append; the only disk writer (identity, session, device state too). **Uploader**:
  one request in flight, deletes only after acknowledgement. Timing goes through the injected
  `Scheduler` (`run`, `after`, `timer`), virtual in tests.
- The write channel is a lock-guarded array bounded at 1000: `enqueue` returns `false` without
  blocking when full and the caller counts `backpressure`. Every flush is a `Flush` message in the
  channel (it includes all earlier events); the upload signal is an atomic flag set by
  `requestUpload()` and cleared when a drain starts. `flush()` triggers and returns;
  `flushBlocking(timeout:)` and `shutdown()` are `package`, for tests and shutdown only.
- Triggers (Queue 2, 3, 7): count (`flush.at`, 30, 1 to 100); interval (`flush.intervalMs`, 60 s,
  1 s to 10 min, a timer that runs only while events are pending, cancelled by any flush);
  backgrounding; network regained; `flush()`; `flush.immediateEvents` (final name after hooks,
  flush after persisting, never a bypass). No upload offline, during backoff, opted out, pending or
  disabled. No public flush policy, pause, resume or background transfer service (Queue 6).
- Batches: at most 100 events and 512 KB before gzip, oldest first, sequential, stop at the first
  failure (Queue 4). Limits: 1000 pending and 3 days from `timestamp`; over the count drop the oldest
  down to 900 in one step; expired ones deleted unsent, at start and before every upload (Queue 5).
- Locked device (iOS Disk 1): on `willBecomeUnavailable` the writer syncs, closes its handles and
  stops draining; events wait in the channel; a read or write that fails with a permission error is
  "locked", not "unreadable"; on `didBecomeAvailable` the writer drains and, on the first
  availability of the process, loads the stores. The uploader reads no batch while locked.

## Storage and JSON

- Stream files, never a whole queue file in a `String`. POSIX descriptors behind the internal
  `FileSystem`, `EventStore` and stores; never replaceable, not encrypted; no protection class of
  the SDK's own, the host's default is inherited (Disk 6, iOS Disk 1).
- `Application Support/rubicon/` (`isExcludedFromBackup = true`): `device.json`, `person.json`,
  `remote-config.json`, `events/v1/{keyHash}/` (16 hex of the key's SHA-256 through `CryptoKit`);
  other key directories are deleted at startup (`api_key_changed`) (Disk 2, iOS Identity 1).
- Segmented log (Disk 1, 3): the open `{index}.tmp` (fixed width, next = max in directory + 1, no
  stored counter) closes at 100 events, 512 KB or flush and is renamed; closed segments are
  immutable; one segment = one batch, deleted after 2xx. One compact UTF-8 line per event, exactly
  the wire event, one `write()` of line + `\n`. Body `{"sent_at":..,"batch":[` + comma-joined lines
  + `]}`, gzipped in memory.
- `FileSystem.sync()` is `fcntl(fd, F_FULLFSYNC)`, `fsync` as the fallback with one DEBUG line; only
  when a segment closes (before rename), on backgrounding, on every store write and before the
  device locks. Never per event (iOS Disk 2). A `.tmp` at startup: keep complete lines, drop a half
  last line (`corrupt`), close it (Disk 4).
- No timestamps for ordering or counting; sizes tracked in memory, read once at startup with
  `attributesOfItem(atPath:)[.size]` from `Rubicon`'s file system (reason `C617.1`); no disk space
  API; a full disk is a failed write (iOS Disk 3).
- Bad lines are skipped (`corrupt`), never logged (ERROR with segment, line number, `message_id`).
  Unreadable segment: retried, deleted after 3 consecutive failures (`UNREADABLE_SEGMENT`). Unknown
  files: deleted with WARN. No quarantine (Disk 5).
- Stores (Disk 7): whole-file JSON with `"v"`, `.tmp` + sync + rename, coalesced on the writer.
  Missing -> create; unreadable (corrupt, newer `v`) -> in-memory, never overwrite; locked -> wait.
  `v` is the file format; raising it is a design discussion with the user.
- Only the internal conversion layer (`json/`) touches `JSONSerialization`: writing with
  `.sortedKeys` from the `PropertyValue` tree (`NSNull` for null, `NSNumber` from the typed enum so
  `true` and `1` stay apart); reading with typed checks and the `CFBoolean` rule; nothing may depend
  on key order (iOS Serialization 1). Non-integral doubles carry seventeen digits; documented for
  the backend, not hidden. Tests compare structurally, parse every line with `JSONDecoder` as the
  independent parser, and run the golden files (Serialization 5).

## HTTP and retry

- `HttpTransport` (iOS HTTP 1 to 4): one `URLSession` per instance from `.ephemeral` (request
  timeout 20 s, resource timeout 45 s, one connection per host, no connectivity wait, no cookies,
  no cache), the transport as delegate refusing redirects (`completionHandler(nil)`),
  `uploadTask(with:from:)` awaited on a `DispatchSemaphore` on the uploader queue,
  `invalidateAndCancel()` at shutdown. gzip through the system `zlib` (`deflateInit2_`, window bits
  `15 + 16`, memory level 8) with `Content-Length`; a failed deflate sends uncompressed with a WARN.
  `Authorization: Bearer {apiKey}` (never in the body); `User-Agent: rubicon-ios/{version} (iOS
  {os})`; headers set on the `URLRequest` in one place. One attempt; no backup host.
- Never throws: `HttpResult` = `success`, `httpError(code, body, retryAfterMs)`,
  `networkFailure(kind)` with `FailureKind` `timeout | dns | connect | tls | io | blocked | cancelled
  | unexpected`, mapped from `URLError.Code` by the table of iOS HTTP 3 (ATS -1022 is `tls`,
  -999 is `cancelled`, unknown codes are `io`). Read at most 4 KB, always drain. `Retry-After` in
  seconds or IMF-fixdate (`HttpDates`). After `connect` or `dns` failures resolve the host with
  `getaddrinfo`: loopback or any-local -> `blocked` (skipped for `localhost` and IP addresses).
  Never log bodies.
- One `switch` over `HttpResult` (Retry 1, 4): 2xx delete. `timeout`, `connect`, `io`, `dns`, 408,
  5xx except 501 and 505, 1xx: keep, back off. 429, or 503 with `Retry-After`: pause. 400, 422, other
  4xx: delete (`rejected`). 401, 403, 404, 410, 413, 3xx, 501, 505, `tls`, `blocked`, `unexpected`:
  keep, pause 1 h ±20 percent, ERROR once. `cancelled` is waiting: no step, no wait, not counted for
  the poison batch, `last_failure = "cancelled"` (iOS Retry 2). Offline is waiting. Success bodies are
  never parsed.
- Backoff 2 s, 10 s, 30 s, 2 min, 5 min, then 10 min, jitter x0.5 to 1.5, reset on success; retries
  by itself with cancellable work items on the uploader queue; network regained ends only network
  waits. `Retry-After` replaces the table: cap 1 h, floor 1 s, jitter x1.0 to 1.1, never shortened
  (Retry 2, 3). Poison batch: after 5 consecutive transient failures of a segment try the next; drop
  it (`retry_exhausted`) after 10 while others succeed. Waits use the `ElapsedClock`; the wall clock
  only for `paused_until`, kept with `pause_kind`, `step`, `last_failure` and per-segment attempts in
  `DeviceStore`, restored at start with the clock guard (Retry 5).
- `NetworkMonitor` keeps the Android interface (`start`, `isConnected`, listeners); connected means
  the platform says so or no update has arrived yet (optimistic); one monitor feeds context, flush
  and retry (iOS Retry 1).

## Logging and diagnostics

- `typealias RubiconLogger = @Sendable (LogLevel, String, (any Error)?) -> Void`, owned by the
  instance; `logging.logger = nil` -> no-op in the core, `os.Logger` in `Rubicon`; never replace a
  developer's logger (iOS Logging 1).
- `enum LogLevel: Int, Sendable { case debug, info, warn, error, off }`, default `.warn`, no runtime
  setter, independent of `debug`. ERROR = data lost or the SDK cannot work; WARN = misconfiguration,
  dropped or changed data; INFO = a few lifecycle lines; DEBUG = every step (Logging 2). Level and
  repeat limit are checked before the message closure runs. A stable `Code` per WARN or ERROR
  (`docs/issue-codes.md`, Platform column), once per process, later at DEBUG; `repeatKey` where a
  decision says once per key (Logging 3). A new code goes into `Code` and the catalogue together.
- Logger and `eventObserver` run behind `CallbackGuard`: a flag in `Thread.current.threadDictionary`
  under `com.rubicon.analytics.inCallback`; log lines and observer updates caused on that thread
  while it is set are ignored. The "threw" halves of Logging 4b exist only in the Objective-C
  wrapper; a Swift closure that traps stops the app, and the documentation says so (iOS Logging 2).
- `typealias EventObserver = @Sendable (EventUpdate) -> Void`; `enum EventUpdate: Sendable { case
  queued(any Event), sent(messageIds:), dropped(messageIds:reason:) }`, not `@frozen`, called on the
  writer and uploader queues, never the main thread; `description` gives ids or counts only.
- Per-reason drop counters in `DeviceStore`: `queue_full`, `expired`, `backpressure`, `before_send`,
  `storage_error`, `corrupt`, `api_key_changed`, `oversize`, `rejected`, `retry_exhausted`; every
  WARN or ERROR code increments an issue counter (Queue 5).
- `SDK Diagnostics` (Logging 5): right before a flush, if a counter is non-zero and 1 h has passed
  since the last (time in `DeviceStore`; a future time counts as now), one event with
  `period_start`, `dropped{total,...}`, `issues{CODE: n}`, no text or values. Counters reset when it
  is written; its own drop is not counted. Sampled by `device_id` (remote `diagnostics_sample_rate`);
  off with `logging.sendDiagnostics = false`; never while opted out, pending or killed.
