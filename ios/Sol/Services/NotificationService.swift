import Foundation
import UserNotifications
import SwiftUI

struct DaemonNotification: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let type: String   // "info" | "warning" | "update"
}

// Observable so HomeView can bind to pending in-app banners
@Observable
@MainActor
final class NotificationService: NSObject {
    static let shared = NotificationService()

    // In-app banner queue — HomeView watches this
    var pending: DaemonNotification? = nil

    private var pollTask: Task<Void, Never>? = nil

    override private init() {
        super.init()
        // Become delegate so iOS shows banners even when app is in foreground
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound, .badge]
        ) { _, _ in }
    }

    // Call when app becomes active; cancels on background
    func startPolling() {
        stopPolling()
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

    func fetchAndDeliver() async {
        guard let notifications = try? await APIClient.shared.fetchNotifications(),
              !notifications.isEmpty else { return }

        for n in notifications {
            if UIApplication.shared.applicationState == .active {
                // App is visible — show our own in-app banner
                pending = n
            } else {
                // App is backgrounded — deliver via system notification
                scheduleSystemNotification(n)
            }
        }
    }

    private func scheduleSystemNotification(_ n: DaemonNotification) {
        let content = UNMutableNotificationContent()
        content.title = n.title
        content.body = n.body
        content.sound = n.type == "warning" ? .defaultCritical : .default
        content.userInfo = ["type": n.type]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: n.id, content: content, trigger: nil)
        )
    }
}

// Show system banner even when app is in foreground (needed for background→foreground edge cases)
extension NotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        handler([.banner, .sound])
    }
}
