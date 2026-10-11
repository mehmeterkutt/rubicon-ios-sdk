/// The stable code of every WARN and ERROR line (Logging 1, 2). The raw values are part of the wire
/// contract: `SDK Diagnostics` reports them in `issues` (Logging 5), and `docs/issue-codes.md`
/// documents each one with the platforms it occurs on. Never rename a code; add a new one.
///
/// Codes that only Android can produce are not in this enum; the catalogue marks them Android-only.
/// Each case's documentation states the level it is logged at, as the catalogue does.
package enum Code: String, Sendable, CaseIterable {
    // MARK: Logging

    /// WARN. The developer's logger threw (Objective-C wrapper only); the platform logger is used from now on.
    case loggerThrew = "LOGGER_THREW"
    /// ERROR. The developer's event observer threw (Objective-C wrapper only); it is switched off.
    case observerThrew = "OBSERVER_THREW"
    /// ERROR. An SDK worker failed with an unexpected error.
    case workerFailed = "WORKER_FAILED"

    // MARK: Configuration

    /// ERROR. The API key is blank; the SDK does nothing.
    case invalidApiKey = "INVALID_API_KEY"
    /// ERROR. The host is not a valid base URL; the SDK does nothing.
    case invalidHost = "INVALID_HOST"
    /// WARN. The host uses `http://`; without an ATS exception the first upload fails.
    case cleartextHost = "CLEARTEXT_HOST"
    /// WARN. A numeric setting was out of bounds and was clamped.
    case settingOutOfBounds = "SETTING_OUT_OF_BOUNDS"
    /// WARN. Settings of a group contradict each other; the group's defaults are used.
    case contradictingSettings = "CONTRADICTING_SETTINGS"
    /// WARN. `network.headers` tried to override a reserved header; it is ignored.
    case reservedHeader = "RESERVED_HEADER"
    /// ERROR. A second instance was created in the process; the first one is returned.
    case secondInstance = "SECOND_INSTANCE"
    /// WARN. The remote configuration could not be fetched or read; the last valid values are kept.
    case remoteConfigFailed = "REMOTE_CONFIG_FAILED"
    /// WARN. A remote configuration value was invalid and is ignored.
    case remoteConfigInvalidValue = "REMOTE_CONFIG_INVALID_VALUE"

    // MARK: Events and properties

    /// WARN. A property or trait was dropped: unsupported type, invalid key or too deep.
    case propertyDropped = "PROPERTY_DROPPED"
    /// WARN. A string value was longer than 1024 characters and was truncated.
    case propertyTruncated = "PROPERTY_TRUNCATED"
    /// WARN. An event had more than 256 properties; the extra ones were dropped.
    case tooManyProperties = "TOO_MANY_PROPERTIES"
    /// WARN. An event or screen name was blank or longer than 255 characters; the event was dropped.
    case invalidEventName = "INVALID_EVENT_NAME"
    /// ERROR. A `beforeSend` hook threw (Objective-C wrapper only); the event was dropped.
    case hookThrew = "HOOK_THREW"
    /// ERROR. A `beforeSend` hook returned what its rules do not allow; the event was dropped.
    case hookViolation = "HOOK_VIOLATION"

    // MARK: Identity

    /// WARN. `identify` was called with a blank user id or one longer than 255 characters.
    case invalidUserId = "INVALID_USER_ID"

    // MARK: Storage

    /// WARN. `device.json`, `person.json` or `remote-config.json` exists but cannot be read; it is left untouched.
    case storeUnreadable = "STORE_UNREADABLE"
    /// ERROR. An event or a store could not be written.
    case storageWriteFailed = "STORAGE_WRITE_FAILED"
    /// ERROR. A stored event line was corrupt and was skipped.
    case corruptLine = "CORRUPT_LINE"
    /// ERROR. A segment could not be read; it is deleted after three failures.
    case unreadableSegment = "UNREADABLE_SEGMENT"
    /// WARN. An unknown file in the events directory was deleted.
    case unknownFile = "UNKNOWN_FILE"

    // MARK: Dropped events (one code per reason that has no code of its own, Queue 5)

    /// WARN. More than 1000 events were pending; the oldest were dropped (`queue_full`).
    case queueFull = "QUEUE_FULL"
    /// WARN. Events older than 3 days were deleted unsent (`expired`).
    case eventsExpired = "EVENTS_EXPIRED"
    /// WARN. Events tracked with another API key were deleted (`api_key_changed`).
    case apiKeyChanged = "API_KEY_CHANGED"
    /// WARN. The write channel was full; the event was dropped (`backpressure`).
    case backpressure = "BACKPRESSURE"
    /// WARN. A serialized event was larger than 32 KB; it was dropped (`oversize`).
    case eventOversize = "EVENT_OVERSIZE"
    /// WARN. The server rejected a batch as malformed (400, 422, other 4xx); it was deleted (`rejected`).
    case batchRejected = "BATCH_REJECTED"
    /// WARN. A batch failed 10 times while others were accepted; it was deleted (`retry_exhausted`).
    case retryExhausted = "RETRY_EXHAUSTED"

    // MARK: Upload

    /// WARN. The host resolves to a local address, as content blockers and encrypted DNS do.
    case hostBlocked = "HOST_BLOCKED"
    /// ERROR. The host answered with a redirect; set `host` to the final URL.
    case httpRedirect = "HTTP_REDIRECT"
    /// ERROR. The TLS handshake failed, or App Transport Security refused the host.
    case tlsFailed = "TLS_FAILED"
    /// ERROR. The HTTP stack failed with an unexpected error.
    case httpUnexpected = "HTTP_UNEXPECTED"
    /// ERROR. The server rejected the API key (401, 403).
    case uploadUnauthorized = "UPLOAD_UNAUTHORIZED"
    /// ERROR. The endpoint does not exist (404, 410); check `host`.
    case uploadEndpointMissing = "UPLOAD_ENDPOINT_MISSING"
    /// ERROR. A gateway rejected the request size (413).
    case uploadTooLarge = "UPLOAD_TOO_LARGE"
    /// ERROR. The server does not support the request (501, 505).
    case uploadNotSupported = "UPLOAD_NOT_SUPPORTED"
    /// WARN. Compressing a request failed; it was sent uncompressed.
    case compressionFailed = "COMPRESSION_FAILED"

    // MARK: Network and lifecycle

    /// WARN. A host pattern of the network observer is invalid; it was ignored.
    case invalidCaptureHost = "INVALID_CAPTURE_HOST"
    /// WARN. The screen-view swizzle could not be installed; screen views are not captured.
    case swizzleFailed = "SWIZZLE_FAILED"
}
