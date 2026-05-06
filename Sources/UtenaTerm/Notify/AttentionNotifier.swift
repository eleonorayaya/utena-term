import AppKit
import UserNotifications

final class AttentionNotifier: NSObject {
    private var lastAttentionState: [UInt: Bool] = [:]  // session.id → was-needing-attention
    private var observer: NSObjectProtocol?
    private var authorized = false

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            self?.authorized = granted
        }
        observer = NotificationCenter.default.addObserver(
            forName: .utenaSessionsDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessions = note.userInfo?["sessions"] as? [Session] else { return }
            self?.process(sessions)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func process(_ sessions: [Session]) {
        guard authorized else {
            // Still record the current state so we don't fire a flood once authorization arrives
            for s in sessions { lastAttentionState[s.id] = s.needsAttention }
            return
        }
        for s in sessions {
            let was = lastAttentionState[s.id] ?? false
            let now = s.needsAttention
            if !was && now {
                fire(for: s)
            }
            lastAttentionState[s.id] = now
        }
        // Clean up entries for sessions that no longer exist
        let alive = Set(sessions.map { $0.id })
        lastAttentionState = lastAttentionState.filter { alive.contains($0.key) }
    }

    private func fire(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = "Claude needs attention"
        content.body = session.name
        content.sound = .default
        content.userInfo = ["sessionID": session.id, "sessionName": session.name]
        let req = UNNotificationRequest(
            identifier: "claude-attention-\(session.id)-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}

extension AttentionNotifier: UNUserNotificationCenterDelegate {
    // Show banner even when our app is foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completion: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completion([.banner, .sound])
    }

    // Click → activate app
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completion: @escaping () -> Void
    ) {
        NSApp.activate(ignoringOtherApps: true)
        completion()
    }
}
