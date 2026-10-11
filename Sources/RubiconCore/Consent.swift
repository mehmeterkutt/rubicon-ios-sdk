/// The consent state when no choice is stored, set with `privacy.defaultConsent` (Privacy 4). A
/// choice made with `optIn` or `optOut` and stored (`privacy.persistConsent`) always wins.
public enum Consent: String, Sendable, CaseIterable {
    /// Events are collected and sent. The default.
    case granted
    /// Events are collected and kept on the device but not sent until `optIn`; `optOut` deletes
    /// them. For apps that ask for consent first.
    case pending
}
