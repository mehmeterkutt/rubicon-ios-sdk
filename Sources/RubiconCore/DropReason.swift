/// Why events were dropped (Queue 5), as reported by `EventUpdate.dropped` and counted in the
/// automatic `SDK Diagnostics` event. The raw values are the wire names. Values may be added in
/// minor versions; a `switch` over it should keep a `default`.
public enum DropReason: String, Sendable, CaseIterable {
    /// More than 1000 events were waiting; the oldest were dropped.
    case queueFull = "queue_full"
    /// The event was older than three days when it could be sent.
    case expired
    /// Events were tracked faster than they could be stored.
    case backpressure
    /// A `beforeSend` hook returned `nil`, failed, or returned an event it may not.
    case beforeSend = "before_send"
    /// The event could not be written, for example on a full disk.
    case storageError = "storage_error"
    /// A stored event was damaged and could not be read.
    case corrupt
    /// The API key changed; events stored for the previous key were deleted.
    case apiKeyChanged = "api_key_changed"
    /// The event was larger than 32 KB.
    case oversize
    /// The server rejected the batch as malformed.
    case rejected
    /// The batch kept failing while others were accepted, and was given up.
    case retryExhausted = "retry_exhausted"
}
