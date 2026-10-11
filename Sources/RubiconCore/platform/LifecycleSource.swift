import Foundation

/// What the platform tells the core about the process (iOS Session 1, iOS Queue 2, iOS Disk 1).
/// The core decides what each one means; the platform only reports.
package enum LifecycleEvent: Sendable, Equatable {
    /// The app is visible (`willEnterForeground`, or already active at startup).
    case foreground
    /// The app left the screen (`didEnterBackground`).
    case background
    /// A non-suspended app is about to be killed; persist the stores, no upload.
    case willTerminate
    /// Protected data goes away (the device is locking); sync and close files.
    case protectedDataWillBecomeUnavailable
    /// Protected data is back; load the stores if needed and resume.
    case protectedDataDidBecomeAvailable
}

/// Whether the app is in the foreground and whether its files are readable, from the application
/// notifications on iOS (iOS Session 1). Sessions, the background flush and the locked state of the
/// store listen to it.
package protocol LifecycleSource: AnyObject, Sendable {
    var isForeground: Bool { get }

    /// `false` only between the two protected-data events, or at a start before the first unlock.
    var isProtectedDataAvailable: Bool { get }

    /// Starts observing; called once by the writer at startup, before `addListener`.
    func start()

    func addListener(_ listener: @escaping @Sendable (LifecycleEvent) -> Void) -> any ListenerToken
}
