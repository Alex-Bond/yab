import MailCore
import SwiftUI

// A mail the page in front is waiting on, first in the field's Now
// (docs/mail.md, "Mail in Now"): its code, its way in, or what it says about
// the sign-in. One row, for the minutes it matters; it takes no room from
// Now's two rows. The corner's offer lasts 30 seconds, this lasts as long as
// the mail is fresh, and it also serves a box Yab can't see: a code asked for
// in an extension's window, on a page that has no box of its own.

enum FieldMail {
    /// How long another site's code stands: it can only be copied, and on
    /// the wrong page it is only useful right after it was asked for.
    nonisolated static let away: TimeInterval = 3 * 60

    /// Words of a mail about signing in, worth a row with no code or link.
    /// Anything else from the site is the site's ordinary mail.
    private nonisolated static let account = #"(?i)\b(log ?in|sign[ -]?in|new device|security|password|verif|blocked|locked)"#

    enum What: Equatable {
        case code(SentCode)
        case link(MailLinks.Found)
        case note
    }

    struct Pick: Equatable {
        let what: What
        let key: String
        let title: String
        let detail: String
        var account: String?
        var thread: String?
        /// From the site of the page in front.
        var own: Bool
        /// The sender's: a code goes only in a box of this address's site.
        var address = ""
    }

    /// The one mail for the row, best first: this site's code, its way in,
    /// another site's code just sent, this site's word about the sign-in.
    /// `live` says a code isn't used up.
    nonisolated static func pick(in mail: [Mailed], host: String?, now: Date = Date(), closed: Set<String> = [],
                                 live: (SentCode) -> Bool = { _ in true }) -> Pick? {
        let open = mail.filter { !closed.contains(key($0)) }
        func own(_ item: Mailed) -> Bool {
            host.map { MailCodes.belongs(address: item.address, from: item.from, subject: item.subject, to: $0) } ?? false
        }
        func code(_ sent: SentCode, own: Bool) -> Pick? {
            guard let read = sent.read else { return nil }
            return Pick(what: .code(sent), key: sent.id, title: title(read), detail: name(sent.from), account: sent.account,
                        thread: sent.thread, own: own, address: open.first { $0.at == sent.at }?.address ?? "")
        }
        let codes = open.filter { now.timeIntervalSince($0.at) < MailCodes.fresh }
        if let host, let sent = MailCodes.codes(in: codes, for: host, now: now).first(where: live),
           let pick = code(sent, own: true) { return pick }
        if let host, let found = MailLinks.found(in: open, for: host, now: now, offered: closed) {
            let item = open.first { key($0) == found.key }
            return Pick(what: .link(found), key: found.key, title: "Sign in to " + MailLinks.name(found),
                        detail: item.map { subject($0.subject) } ?? "", account: found.account, thread: found.thread, own: true)
        }
        let others = MailCodeMatching.codes(in: open, now: now, since: now.addingTimeInterval(-away)) { !own($0) }
        if let sent = others.sorted(by: { ($0.at ?? .distantPast) > ($1.at ?? .distantPast) }).first(where: live),
           let pick = code(sent, own: false) { return pick }
        let noted = open.filter { item in
            let age = now.timeIntervalSince(item.at)
            return age >= -30 && age < MailLinks.fresh && item.unread && !item.junk && own(item)
                && item.subject.range(of: account, options: .regularExpression) != nil
        }
        guard let item = noted.max(by: { $0.at < $1.at }) else { return nil }
        return Pick(what: .note, key: key(item), title: subject(item.subject), detail: name(item.from.isEmpty ? item.address : item.from),
                    account: item.account, thread: item.thread, own: true)
    }

    nonisolated static func key(_ item: Mailed) -> String {
        "\(item.account ?? ""):\(item.thread ?? ""):\(item.at.timeIntervalSince1970)"
    }

    /// What the code is for, as Mail's card says it.
    nonisolated static func title(_ read: MailCodeRead) -> String {
        if read.purpose == .purchase {
            let facts = [read.amount, read.merchant.map { "at " + $0 }].compactMap { $0 }.joined(separator: " ")
            return facts.isEmpty ? "Card transaction" : facts
        }
        switch read.purpose {
        case .signIn: return "Sign-in code"
        case .confirmEmail: return "Confirm email"
        case .resetPassword: return "Reset password"
        case .newDevice: return "New device"
        default: return "Verification code"
        }
    }

    /// "LastPass Security Notification: Login attempt blocked" says it in
    /// its last part.
    nonisolated static func subject(_ words: String) -> String {
        let last = words.components(separatedBy: ": ").last?.trimmingCharacters(in: .whitespaces) ?? ""
        return last.isEmpty ? words : last
    }

    private nonisolated static func name(_ from: String) -> String {
        MailLinks.name(MailLinks.Found(url: URL(fileURLWithPath: "/"), site: from, from: from, key: ""))
    }

    /// The row on screen now, read by the row's own views and its actions.
    @MainActor static var shown: Pick?
    /// Put away with Done, or taken: not again this launch.
    @MainActor static var closed = Set<String>()
    @MainActor private static var mail: (list: [Mailed], changed: Int, at: Date)?

    /// The list's opening is no place for a query, and most open on no new
    /// mail at all.
    @MainActor static func fresh(now: Date) -> [Mailed] {
        let center = MailCenter.shared
        if let fake = MailCodes.fakeMail.withLock({ $0 }) { return fake }
        guard center.connected else { return [] }
        if let mail, mail.changed == center.changed, now.timeIntervalSince(mail.at) < 5 { return mail.list }
        let list = center.recent(minutes: MailCodes.fresh / 60)
        mail = (list, center.changed, now)
        return list
    }

    @MainActor static var item: MailCodeItem? {
        guard let shown, case .code(let sent) = shown.what, let read = sent.read, let at = sent.at else { return nil }
        return MailCodeItem(account: sent.account ?? "", message: sent.message ?? sent.id, thread: sent.thread ?? "",
                            address: shown.address, at: at, read: read)
    }
}

@MainActor
extension Browser {
    /// Now's first row, while a mail is about the page in front.
    func mailNowRow(now: Date) -> Suggestion? {
        FieldMail.shown = nil
        guard prefs.mailCodes, !privateBrowsing else { return nil }
        let host = active.flatMap { tab in tab.address.flatMap { MailLinks.secure($0) ? curtain.host(of: $0) : nil } }
        let done = FieldMail.closed.union(MailLinks.opened)
        guard let pick = FieldMail.pick(in: FieldMail.fresh(now: now), host: host, now: now, closed: done,
                                        live: { MailCodeState.shared.available($0) }) else { return nil }
        FieldMail.shown = pick
        return Suggestion(key: pick.title, title: pick.detail, url: nil, kind: .page("mail-now"))
    }

    func mailNowActions(primary: @escaping @MainActor () -> Void) -> [FieldAction] {
        guard let pick = FieldMail.shown else { return [] }
        var out: [FieldAction] = []
        switch pick.what {
        case .code:
            if let item = FieldMail.item, pick.own, codeBox(for: item) != nil {
                out.append(FieldAction(id: "fill", title: "Fill Code", symbol: "yab.tab.left", run: primary))
                out.append(FieldAction(id: "copy", title: "Copy", keys: "⌘C", symbol: "yab.copy", featured: true) { self.copyMailNow() })
            } else {
                out.append(FieldAction(id: "copy", title: "Copy Code", symbol: "yab.copy", run: primary))
            }
        case .link:
            out.append(FieldAction(id: "open", title: "Open Link", symbol: "arrow.up.right", run: primary))
        case .note:
            out.append(FieldAction(id: "open", title: "Open Mail", symbol: "envelope", run: primary))
        }
        if pick.what != .note, let account = pick.account, let thread = pick.thread {
            out.append(FieldAction(id: "mail", title: "Open Mail", symbol: "envelope") {
                self.close()
                self.showMail()
                MailDesk.shared.openThread(account: account, thread: thread)
            })
        }
        out.append(FieldAction(id: "done", title: "Done", keys: Keymap.shared.text(.fieldDone), symbol: "yab.check") {
            FieldMail.closed.insert(pick.key)
            FieldMail.shown = nil
            self.picked = nil
            self.query.pointed = nil
            self.query.acting = nil
            self.typed = ""
        })
        return out
    }

    func takeMailNow() {
        guard let pick = FieldMail.shown else { return }
        switch pick.what {
        case .code:
            guard let item = FieldMail.item else { return }
            if pick.own, let box = codeBox(for: item) {
                close()
                fillCode(item, into: box)
            } else {
                copyMailNow()
            }
        case .link(let found):
            guard let id = active?.id else { return }
            close()
            MailLinks.opened.insert(found.key)
            openMailLink(found, in: id)
        case .note:
            close()
            guard let account = pick.account, let thread = pick.thread else { return }
            showMail()
            MailDesk.shared.openThread(account: account, thread: thread)
        }
    }

    /// The field goes with it, for the paste: the clipboard shows nothing,
    /// so the corner says.
    func copyMailNow() {
        guard let item = FieldMail.item else { return }
        MailCodeState.shared.copy(item)
        close()
        announce("Code copied", mark: "yab.copy")
    }
}

/// The row's mark: the site it is about, or a mail from somewhere else.
struct FieldMailMark: View {
    let browser: Browser

    var body: some View {
        if FieldMail.shown?.own == true, let tab = browser.active {
            Mark(icon: tab.icon, letter: tab.monogram, size: Omnibox.tile - 2)
                .frame(width: Omnibox.tile, height: Omnibox.tile)
        } else {
            FieldMark(symbol: "envelope")
        }
    }
}

/// The row's end: the code, or that it is a mail.
struct FieldMailEnd: View {
    var lit = false

    var body: some View {
        if let item = FieldMail.item {
            MailCodeChip(item: item, size: 13.5) // design: a row's words' size
        } else {
            Text("Mail")
                .font(.system(size: 13.5))
                .foregroundStyle(lit ? Color.white.opacity(0.8) : Palette.muted)
                .lineLimit(1)
        }
    }
}
