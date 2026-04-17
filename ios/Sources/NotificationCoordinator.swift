import Foundation
import UserNotifications

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private enum ActionID {
        static let openThread = "helm.notification.open-thread"
        static let approve = "helm.notification.approve"
        static let decline = "helm.notification.decline"
    }

    private enum CategoryID {
        static let update = "helm.notification.update"
        static let approval = "helm.notification.approval"
    }

    static let shared = NotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    var onThreadOpened: ((String) -> Void)?
    var onApprovalAction: ((String, String, String?) -> Void)?

    private override init() {
        super.init()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: CategoryID.update,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.openThread,
                        title: "Open",
                        options: [.foreground]
                    ),
                ],
                intentIdentifiers: []
            ),
            UNNotificationCategory(
                identifier: CategoryID.approval,
                actions: [
                    UNNotificationAction(
                        identifier: ActionID.approve,
                        title: "Approve",
                        options: []
                    ),
                    UNNotificationAction(
                        identifier: ActionID.decline,
                        title: "Decline",
                        options: [.destructive]
                    ),
                    UNNotificationAction(
                        identifier: ActionID.openThread,
                        title: "Open",
                        options: [.foreground]
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
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

    func post(
        title: String,
        body: String,
        threadID: String,
        approvalID: String? = nil,
        timeSensitive: Bool = false
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = threadID
        content.categoryIdentifier = approvalID == nil ? CategoryID.update : CategoryID.approval
        content.interruptionLevel = (approvalID != nil || timeSensitive) ? .timeSensitive : .active
        content.userInfo = [
            "threadId": threadID,
            "approvalId": approvalID ?? "",
        ]

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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let actionIdentifier = response.actionIdentifier
        guard let threadID = userInfo["threadId"] as? String else {
            return
        }

        let approvalID = (userInfo["approvalId"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        await MainActor.run {
            switch actionIdentifier {
            case ActionID.approve:
                if let approvalID {
                    onApprovalAction?(approvalID, "accept", threadID)
                }
            case ActionID.decline:
                if let approvalID {
                    onApprovalAction?(approvalID, "decline", threadID)
                }
            case UNNotificationDefaultActionIdentifier, ActionID.openThread:
                onThreadOpened?(threadID)
            default:
                onThreadOpened?(threadID)
            }
        }
    }
}
