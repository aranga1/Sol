import Foundation
import UserNotifications
import UIKit

struct DaemonNotification: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let type: String
}

final class NotificationService: NSObject, @unchecked Sendable {
    static let shared = NotificationService()

    private var pollTask: Task<Void, Never>?

    override private init() {
        super.init()
    }

    // Called from AppDelegate.didFinishLaunching — must be early
    func setup() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { granted, error in
            if !granted {
                print("[Sol] Notification permission denied: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchAndDeliver()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func fetchAndDeliver() async {
        guard let notifications = try? await APIClient.shared.fetchNotifications(),
              !notifications.isEmpty else { return }

        for n in notifications {
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.body
            content.sound = n.type == "warning" ? .defaultCritical : .default
            content.userInfo = ["type": n.type]

            let request = UNNotificationRequest(
                identifier: n.id, content: content, trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// Show banner + play sound even when app is in foreground
extension NotificationService: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }
}
