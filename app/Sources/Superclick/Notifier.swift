import AppKit
import UserNotifications

/// macOS notifications for closed bubbles (M4, SPEC flow 3): "shop needs your
/// OK" with Allow, Deny and a typed reply, and "Answer ready". Nothing is ever
/// shown on the cursor (DECISIONS); the menu bar and these notifications carry it.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    enum Action: Equatable {
        case show
        case allow
        case deny
        /// Typed in the notification: sent to Claude instead of the action (DECISIONS: every choice takes typed input).
        case reply(String)
    }

    /// Called on the main actor when the user acts on a notification.
    var onAction: ((_ requestID: String, _ approvalID: String?, _ action: Action) -> Void)?

    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private static let approvalCategory = "approval"
    private static let answerCategory = "answer"

    func setUp() {
        center.delegate = self
        let allow = UNNotificationAction(identifier: "allow", title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive])
        let reply = UNTextInputNotificationAction(
            identifier: "reply", title: "Tell Claude instead…", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "What to do instead")
        let show = UNNotificationAction(identifier: "show", title: "Show", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.answerCategory, actions: [show], intentIdentifiers: []),
        ])
    }

    /// Asks once, the first time there's something to say.
    private func authorized(_ then: @escaping @MainActor () -> Void) {
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in
                switch status {
                case .authorized, .provisional: then()
                case .notDetermined:
                    self.center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
                        if ok { Task { @MainActor in then() } }
                    }
                default: break
                }
            }
        }
    }

    func approvalNeeded(requestID: String, project: String, approval: PendingApproval) {
        let content = UNMutableNotificationContent()
        content.title = "\(project) needs your OK"
        content.subtitle = approval.tool
        content.body = String((approval.detail.isEmpty ? approval.summary : approval.detail).prefix(300))
        content.categoryIdentifier = Self.approvalCategory
        content.sound = .default
        content.threadIdentifier = requestID
        content.userInfo = ["requestID": requestID, "approvalID": approval.id]
        post(id: "approval-\(approval.id)", content, unless: { self.cleared.contains(approval.id) })
    }

    func answerReady(requestID: String, project: String, asked: String, answer: String, failed: Bool) {
        let content = UNMutableNotificationContent()
        content.title = failed ? "\(project): the request failed" : "Answer ready in \(project)"
        content.subtitle = asked
        content.body = String((answer.split(separator: "\n").first ?? "").prefix(200))
        content.categoryIdentifier = Self.answerCategory
        content.threadIdentifier = requestID
        content.userInfo = ["requestID": requestID]
        post(id: "answer-\(requestID)", content)
    }

    /// Approvals already answered or gone. Checked again just before posting, since asking
    /// for permission is asynchronous and a quick answer in the bubble can come first.
    private var cleared = Set<String>()

    private func post(id: String, _ content: UNMutableNotificationContent, unless gone: @escaping @MainActor () -> Bool = { false }) {
        authorized {
            guard !gone() else { return }
            self.center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Takes an approval's notification away once it's answered somewhere else.
    func clear(approvalID: String) {
        if cleared.count > 500 { cleared.removeAll() }
        cleared.insert(approvalID)
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(approvalID)"])
    }

    func clear(requestID: String) {
        center.removeDeliveredNotifications(withIdentifiers: ["answer-\(requestID)"])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let requestID = info["requestID"] as? String
        let approvalID = info["approvalID"] as? String
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let actionID = response.actionIdentifier
        completionHandler()
        guard let requestID else { return }
        Task { @MainActor in
            let action: Action
            switch actionID {
            case "allow": action = .allow
            case "deny": action = .deny
            case "reply":
                let text = typed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                action = text.isEmpty ? .deny : .reply(text)
            default: action = .show
            }
            self.onAction?(requestID, approvalID, action)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Superclick has no windows in front most of the time, so show banners even when it's "active".
        completionHandler([.banner, .list, .sound])
    }
}
