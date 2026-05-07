import Foundation

/// Manages error message display with auto-dismiss timeout.
/// Centralizes the Timer pattern used by Workspaces and PullRequests.
public class OverlayErrorManager {
    private var message: String?
    private var dismissTimer: Timer?

    /// The current error message, or nil if none.
    public var errorMessage: String? { message }

    /// Show an error message that will automatically dismiss after timeout.
    public func show(_ message: String, timeout: TimeInterval = 3.0, onDismiss: @escaping () -> Void = {}) {
        self.message = message
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.clear()
            onDismiss()
        }
    }

    /// Clear any current error message and cancel auto-dismiss.
    public func clear() {
        message = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// Call this on dealloc or window close to clean up the timer.
    public func tearDown() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }
}
