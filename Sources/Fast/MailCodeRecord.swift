import Foundation
import MailCore

/// One code offered: what it is, where it came from and when.
struct SentCode: Equatable, Identifiable {
    /// `key` is Yab's own two-factor key, `apple` one kept in Apple
    /// Passwords and read through its helper.
    enum Source: Equatable { case mail, text, key, apple }
    let id: String
    let code: String
    /// Who sent it, as it says: "Linear", "+1 415 555 0100"; the account for
    /// a key.
    let from: String
    let at: Date?
    let source: Source
    /// Sent by the site whose box this is, not only some fresh code.
    let mine: Bool
    /// The mail it came in, when Mail keeps it: archived after use if
    /// Settings › Autofill says so.
    var thread: String? = nil
    var account: String? = nil
    var message: String? = nil
    var read: MailCodeRead? = nil

    /// An authenticator's code, made for now: never used up, never archived.
    var made: Bool { source == .key || source == .apple }
}

/// What this particular verification step asks for. An SMS challenge must
/// not fall back to a number from mail or an authenticator.
struct CodeRequest: Equatable {
    var source: SentCode.Source?
    var digits: Int?

    nonisolated func accepts(_ code: SentCode) -> Bool {
        // An authenticator's box takes Apple Passwords' code too; one that
        // Passwords hands over only after Touch ID has no digits to count yet.
        let from = source == nil || source == code.source || (source == .key && code.source == .apple)
        return from && (digits == nil || digits == code.code.count || (code.source == .apple && code.code.isEmpty))
    }
}


/// A mail as Gmail's feed has it: who, the subject, the start of the text.
struct Mailed: Equatable {
    var from: String
    var address: String
    var subject: String
    var text: String
    var at: Date
    /// Where Mail keeps it; nil from Gmail's feed.
    var thread: String? = nil
    var account: String? = nil
    /// Its HTML, where Mail keeps the body: a sign-in link is a button's
    /// address (MailLinks). Gmail's feed has none.
    var html: String? = nil
    /// Not yet read: a link read in the mail may have been followed there.
    var unread = true
    /// In Spam or Trash: where a mail with a forged sender usually lands.
    var junk = false
    var message: String? = nil
    var read: MailCodeRead? = nil
}

/// Time, resend and identity policy, independent of the browser's domain matcher.
enum MailCodeMatching {
    static func codes(in mail: [Mailed], now: Date, since: Date? = nil, belongs: (Mailed) -> Bool) -> [SentCode] {
        var newest: [String: Date] = [:]
        let parsed = mail.compactMap { mail -> (Mailed, MailCodeRead)? in
            guard !mail.junk, now.timeIntervalSince(mail.at) >= -30, belongs(mail) else { return nil }
            // Connected Mail is read once by Sense; only the feed has a fallback parse.
            let stored = mail.account != nil && mail.message != nil
            guard let read = mail.read ?? (stored ? nil : MailCodeWords.read(subject: mail.subject, text: mail.text, html: mail.html, received: mail.at)) else { return nil }
            newest[mail.address] = max(newest[mail.address] ?? .distantPast, mail.at)
            return (mail, read)
        }
        return parsed.filter { mail, read in
            let age = now.timeIntervalSince(mail.at)
            return age >= -30 && now < (read.expires ?? mail.at.addingTimeInterval(MailCodeRead.defaultLifetime))
                && mail.at >= (since ?? .distantPast) && mail.at == newest[mail.address]
        }.map { mail, read in
            let id = mail.message.flatMap { message in mail.account.map { "mail:\($0):\(message)" } }
                ?? "mail:\(mail.at.timeIntervalSince1970):\(read.code)"
            return SentCode(id: id, code: read.code, from: mail.from.isEmpty ? mail.address : mail.from, at: mail.at,
                            source: .mail, mine: true, thread: mail.thread, account: mail.account,
                            message: mail.message, read: read)
        }
    }
}
