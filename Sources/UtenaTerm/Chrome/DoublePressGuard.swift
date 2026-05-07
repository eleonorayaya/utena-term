import Foundation

/// Generic double-press confirmation guard: tracks a pending action and confirms it
/// if pressed again within a timeout window.
///
/// Usage:
/// ```swift
/// var guard = DoublePressGuard<UInt>()
/// if guard.confirm(sessionId) {
///     // Second press within timeout — execute action
///     performAction(sessionId)
/// } else {
///     // First press — show affordance
///     showPressAgainPrompt(sessionId)
///     // View reads guard.pendingKey to highlight the row
/// }
/// ```
public struct DoublePressGuard<Key: Equatable> {
    private var pending: (key: Key, expires: Date)?

    /// Check if this is a second press within the timeout window, or record it as the first press.
    /// Returns true only if the same key was pressed again before expiry.
    public mutating func confirm(_ key: Key, timeout: TimeInterval = 3) -> Bool {
        let now = Date()
        if let p = pending, p.key == key, p.expires > now {
            pending = nil
            return true
        }
        pending = (key, now.addingTimeInterval(timeout))
        return false
    }

    /// Clear any pending press (e.g., on timeout or user cancellation).
    public mutating func clear() {
        pending = nil
    }

    /// Return the currently pending key if it hasn't expired, or nil.
    public var pendingKey: Key? {
        guard let p = pending, p.expires > Date() else { return nil }
        return p.key
    }
}
