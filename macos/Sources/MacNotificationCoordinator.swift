import Foundation
import UserNotifications

@MainActor
final class MacNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = MacNotificationCoordinator()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .badge, .sound])
            } catch {
                return false
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func authorizationDescription() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized:
            return "Enabled"
        case .provisional:
            return "Provisional"
        case .ephemeral:
            return "Ephemeral"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        @unknown default:
            return "Unknown"
        }
    }

    func post(title: String, body: String, threadID: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadID
        content.userInfo = ["threadId": threadID]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
