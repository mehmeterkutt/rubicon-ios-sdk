import Foundation

/// How the platform brackets the background flush (iOS Queue 2): it begins its background task when
/// the app goes to the background, asks to be told when the uploader's drain ends, and cancels the
/// request in flight when the task is about to expire. Implemented by the real instance, reached
/// through the factory's `onCreated` like `AutomaticCapture`.
package protocol BackgroundFlushControl: AnyObject, Sendable {
    /// `onDone` runs on the uploader queue when the drain that follows the background flush ends,
    /// whatever ended it, or at once when the uploader cannot run.
    func beginBackgroundFlush(onDone: @escaping @Sendable () -> Void)

    /// The task is about to expire: cancel the request in flight; the batch stays on disk.
    func expireBackgroundFlush()
}
