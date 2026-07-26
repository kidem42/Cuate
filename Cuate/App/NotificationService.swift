import Foundation
import Combine
import UserNotifications
import AppKit

extension Notification.Name {
    /// A notification banner was clicked: summon the panel and switch to the
    /// agent role in userInfo["roleID"] (AppDelegate/ChatWindow listen).
    static let agentNotificationOpened = Notification.Name("agentNotificationOpened")
}

/// System-notification subsystem (AGENT-ADDONS-NOTES.md §7.1) — built for
/// the agent addons: an agent works asynchronously for minutes and can ask
/// for permission while the panel is closed. Ordinary providers never
/// needed banners (the reply streams while the user watches), which is why
/// the project had zero UserNotifications calls until now.
///
/// Rules encoded here:
/// - permission is requested when the ADDON is enabled, never at app start
///   (the TCC pattern of `CalendarAddon.requestAccessIfNeeded`);
/// - categories register early, else banner buttons don't render;
/// - duplicates are suppressed while the same conversation is visibly open;
/// - stale approval banners are revoked when resolved elsewhere;
/// - a click summons the panel and switches to the role's conversation;
/// - denial degrades to the status-bar indicator, not to silence.
@MainActor
final class NotificationService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    /// Whether the user granted notification permission (nil = not asked).
    @Published private(set) var authorized: Bool?
    /// Pending approvals count — the status-bar/menu fallback indicator when
    /// notifications are denied.
    @Published private(set) var pendingApprovalCount = 0

    private var center: UNUserNotificationCenter { .current() }

    // MARK: Category / action identifiers

    enum Category {
        static let approval = "agent.approval"
        static let question = "agent.question"
        static let turnDone = "agent.turnDone"
        static let jobFailed = "agent.jobFailed"
    }

    enum Action {
        static let allow = "agent.approval.allow"
        static let deny = "agent.approval.deny"
        static let reply = "agent.question.reply"
    }

    private override init() {
        super.init()
    }

    /// Registers categories and takes over delegate duties. Called once from
    /// app startup — registering is inert until permission is granted, and
    /// categories MUST exist before the first banner or its buttons vanish.
    func activate() {
        center.delegate = self
        let approval = UNNotificationCategory(
            identifier: Category.approval,
            actions: [
                UNNotificationAction(identifier: Action.allow, title: AGL("agent.approval.allow"),
                                     options: [.authenticationRequired]),
                UNNotificationAction(identifier: Action.deny, title: AGL("agent.approval.deny"),
                                     options: [.destructive])
            ],
            intentIdentifiers: []
        )
        let question = UNNotificationCategory(
            identifier: Category.question,
            actions: [
                UNTextInputNotificationAction(identifier: Action.reply, title: AGL("agent.notif.reply"),
                                              options: [],
                                              textInputButtonTitle: AGL("agent.notif.reply"),
                                              textInputPlaceholder: "")
            ],
            intentIdentifiers: []
        )
        let turnDone = UNNotificationCategory(identifier: Category.turnDone, actions: [], intentIdentifiers: [])
        let jobFailed = UNNotificationCategory(identifier: Category.jobFailed, actions: [], intentIdentifiers: [])
        center.setNotificationCategories([approval, question, turnDone, jobFailed])
        refreshAuthorization()
    }

    /// Requests permission — called at the moment the user flips an agent
    /// addon's master switch (predictable TCC moment, never mid-chat).
    func requestPermissionIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else {
                DispatchQueue.main.async { self?.refreshAuthorization() }
                return
            }
            self?.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async { self?.authorized = granted }
            }
        }
    }

    private func refreshAuthorization() {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                switch settings.authorizationStatus {
                case .notDetermined: self?.authorized = nil
                case .denied: self?.authorized = false
                default: self?.authorized = true
                }
            }
        }
    }

    // MARK: - Posting

    /// Whether a banner for this conversation should be suppressed: the
    /// panel is visible, key, and showing that same conversation — the
    /// inline UI is already on screen (§7.1 duplicate rule).
    private func isConversationOnScreen(_ conversationKey: String?) -> Bool {
        guard let key = conversationKey,
              let panel = FloatingPanelWindow.chatPanel, panel.isVisible,
              NSApp.isActive else { return false }
        return ChatWindowBridge.chatStore?.conversation.storageKey == key
    }

    /// Long agent turn finished while the user looked elsewhere.
    func postTurnCompleted(roleID: String, roleName: String, preview: String, conversationKey: String) {
        // Breadcrumbs: "why no banner" must be answerable from the log.
        guard authorized == true else {
            Diagnostics.log("notif", "turnDone dropped — authorization=\(String(describing: authorized))")
            return
        }
        guard !isConversationOnScreen(conversationKey) else {
            Diagnostics.log("notif", "turnDone suppressed — conversation on screen")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = roleName
        content.body = HermesSettings.shared.hideNotificationDetails
            ? AGL("agent.notif.turnDone")
            : String(preview.prefix(160))
        content.categoryIdentifier = Category.turnDone
        content.userInfo = ["roleID": roleID]
        post(id: "turn-\(conversationKey)", content: content)
    }

    /// The agent asked the human for permission (dormant on Hermes 0.19.0 —
    /// no mid-run approval frames yet; wired for when they arrive).
    func postApprovalRequest(_ approval: AgentApproval, roleID: String, roleName: String, conversationKey: String) {
        pendingApprovalCount += 1
        guard authorized == true, !isConversationOnScreen(conversationKey) else { return }
        let content = UNMutableNotificationContent()
        content.title = String(format: AGL("agent.notif.approvalTitle"), roleName)
        content.body = HermesSettings.shared.hideNotificationDetails
            ? AGL("agent.notif.approvalHidden")
            : approval.subject
        content.categoryIdentifier = Category.approval
        content.interruptionLevel = .timeSensitive // must pierce Focus
        content.userInfo = ["roleID": roleID, "approvalID": approval.id]
        post(id: "approval-\(approval.id)", content: content)
    }

    /// The approval was resolved (here or from another client): the banner
    /// must not keep dead buttons in Notification Center.
    func revokeApproval(id: String) {
        pendingApprovalCount = max(0, pendingApprovalCount - 1)
        center.removeDeliveredNotifications(withIdentifiers: ["approval-\(id)"])
        center.removePendingNotificationRequests(withIdentifiers: ["approval-\(id)"])
    }

    private func post(id: String, content: UNNotificationContent) {
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
            Diagnostics.log("notif", "posted id=\(id) error=\(error.map { String(describing: $0) } ?? "nil")")
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let roleID = userInfo["roleID"] as? String
        let approvalID = userInfo["approvalID"] as? String
        let action = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await MainActor.run {
            NotificationService.shared.handleResponse(
                action: action, roleID: roleID, approvalID: approvalID, replyText: replyText
            )
        }
    }

    private func handleResponse(action: String, roleID: String?, approvalID: String?, replyText: String?) {
        switch action {
        case Action.allow, Action.deny:
            if let approvalID {
                resolveApprovalFromBanner(approvalID: approvalID, roleID: roleID, approve: action == Action.allow)
            }
        case Action.reply:
            if let replyText, let roleID {
                sendBannerReply(replyText, roleID: roleID)
            }
        default:
            // Body click: summon the panel on the role's conversation.
            if let roleID {
                NotificationCenter.default.post(
                    name: .agentNotificationOpened, object: nil, userInfo: ["roleID": roleID]
                )
            }
        }
    }

    /// Approval from the banner works without opening the panel.
    private func resolveApprovalFromBanner(approvalID: String, roleID: String?, approve: Bool) {
        revokeApproval(id: approvalID)
        guard let roleID,
              let role = HermesAddon.shared.roles.first(where: { $0.id == roleID }) else { return }
        let session = HermesAddon.shared.agentSession(for: role)
        Task {
            try? await session.resolveApproval(id: approvalID, decision: approve ? .approve : .deny)
        }
    }

    /// Text reply typed straight into the banner goes to the session as a
    /// normal user turn (fire-and-forget; the transcript mirrors it back).
    private func sendBannerReply(_ text: String, roleID: String) {
        guard let role = HermesAddon.shared.roles.first(where: { $0.id == roleID }) else { return }
        let session = HermesAddon.shared.agentSession(for: role)
        Task {
            for try await _ in session.send(text: text, attachments: []) {}
        }
    }
}
