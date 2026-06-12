import Foundation
import UserNotifications

struct DaemonNotification: Decodable {
    let id: String
    let title: String
    let body: String
    let type: String
}

private struct NotificationsResponse: Decodable {
    let notifications: [DaemonNotification]
}

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private init() {}

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func fetchAndDeliver() {
        Task {
            guard let notifications = try? await APIClient.shared.fetchNotifications(),
                  !notifications.isEmpty else { return }
            for n in notifications {
                schedule(n)
            }
        }
    }

    private func schedule(_ n: DaemonNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = n.type == "warning" ? .defaultCritical : .default
        content.userInfo = ["type": n.type]

        let request = UNNotificationRequest(
            identifier: n.id,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
