import Foundation
import SyncKit

// The Mac's Now rows about mail, for the iPhone's Now widget
// (docs/sync.md, `now`). The iPhone has no mail of its own: a row carries
// what its mail app needs to find the thread, the Gmail thread on the web
// and the last message's Message-ID, and the iPhone opens it there. Each
// Mac says only its own rows; a row that leaves Now here leaves the phone.

enum SyncNow {
    static let now = SyncCollection.now
    /// The most rows the widget shows, as Now's mail rows (Noticing.mail).
    static let limit = 3

    struct Row: Equatable {
        /// The row's id on the Mac, "mail.<thread>".
        var id: String
        var title: String
        var detail: String
        /// The sender's name, kept on a locked iPhone where the words go.
        var who: String
        /// The sender's site, for the row's mark.
        var host: String
        /// The thread in Gmail on the web.
        var web: String
        /// The last message's Message-ID, for a mail app that finds messages by it.
        var message: String
    }

    /// The mail rows Now shows on this Mac, in its order.
    /// `message` is a thread's last Message-ID (MailCenter.lastMessageID).
    static func rows(_ hints: [Hint], message: (String, String) -> String) -> [Row] {
        Array(hints.compactMap { hint -> Row? in
            guard hint.source == .noticed, hint.id.hasPrefix("mail."), let (account, thread) = Hints.mailThread(hint.url) else { return nil }
            let host: String = switch hint.icon {
            case .site(let site), .picture(_, let site?): site
            default: ""
            }
            return Row(id: hint.id, title: hint.title, detail: hint.detail, who: hint.sender?.name ?? "", host: host,
                       web: web(account: account, thread: thread), message: message(account, thread))
        }.prefix(limit))
    }

    /// Gmail's page of a thread, in the account it is in.
    static func web(account: String, thread: String) -> String {
        let user = account.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? account
        return "https://mail.google.com/mail/u/\(user)/#all/\(thread)"
    }

    static func records(_ rows: [Row], device: String) -> SyncShapes.Collection {
        var out: SyncShapes.Collection = [:]
        for (order, row) in rows.enumerated() {
            var fields: [String: Value] = ["title": .string(row.title), "detail": .string(row.detail), "who": .string(row.who),
                                           "host": .string(row.host), "web": .string(row.web), "order": .number(Double(order)),
                                           "device": .string(device)]
            if !row.message.isEmpty { fields["message"] = .string(row.message) }
            out[row.id] = fields
        }
        return out
    }

    /// This Mac's rows told to the journal; another Mac's are its own.
    static func reconcile(_ journal: Journal, _ rows: [Row], device: String) throws {
        try journal.reconcile(now, records(rows, device: device), within: { $0.visible["device"]?.string == device }, blank: true)
    }
}

extension MailCenter {
    /// The Message-ID of a thread's newest message here, or "".
    func lastMessageID(account: String, thread: String) -> String {
        engines[account]?.store.messages(thread: thread).last?.rfcID ?? ""
    }
}
