import UserNotifications
import SyncKit

/// The sync server's alert of an agent's question says only "Yab: Needs
/// your answer" and carries the question sealed. Here, on this iPhone, it is
/// opened with the Sync key and said in full: who asks, what, where, how
/// much (ApprovalNotice). A question that can't be opened keeps the words it
/// came with, and the app says it once its line catches up.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler handler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        self.handler = handler
        self.content = content
        if let shown = ApprovalNotice.open(request.content.userInfo, seal: SyncKeychain.standard().local) {
            _ = ApprovalNotice.content(shown, into: content)
        }
        content.userInfo["yab"] = nil
        handler(content)
        self.handler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler, let content { handler(content) }
        handler = nil
    }
}
