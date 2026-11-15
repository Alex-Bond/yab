import AppKit

// Sign-in links from mail (docs/mail.md, "Sign-in links from mail"). A site
// that signs you in without a password mails a link; when that mail comes
// from the site of the page in front, the corner says "Sign in to Linear"
// and Open follows the link in that tab. Nothing shows while the mail is on
// its way, and the link is never fetched before it is opened: it works once.

enum MailLinks {
    /// How fresh a mail still counts: a link like this is asked for and
    /// used within moments.
    nonisolated static let fresh: TimeInterval = 3 * 60

    /// How long the corner offers it: long enough to come back from
    /// another window and still find it.
    static let stay: TimeInterval = 30

    /// Hosts that sign people in for many sites, a link to which is fine in
    /// mail from the site itself, and the mail services that wrap every
    /// link of a mail in one of their own to count the clicks.
    nonisolated static let signers: Set<String> = [
        "auth0.com", "supabase.co", "firebaseapp.com", "stytch.com", "workos.com", "authkit.app",
        "magic.link", "kinde.com", "descope.com", "frontegg.com", "accounts.dev", "clerk.com",
    ]
    nonisolated static let wrappers: Set<String> = [
        "sendgrid.net", "mailgun.org", "mandrillapp.com", "list-manage.com", "mcsv.net", "awstrack.me",
        "sparkpostmail.com", "customeriomail.com", "mjt.lu", "hubspotlinks.com", "postmarkapp.com", "pstmrk.it", "rs6.net",
    ]

    /// One link found for a site: where it goes and the mail it came in.
    struct Found: Equatable {
        let url: URL
        let site: String
        let from: String
        let key: String
        var thread: String? = nil
        var account: String? = nil
    }

    /// The newest sign-in link mailed by the site of `host`, not offered
    /// before. The sender's domain must be the site's, as for codes, and
    /// the link must go to the site itself, to a host that signs people in
    /// for it, or through the sender's mail service.
    nonisolated static func found(in mail: [Mailed], for host: String, now: Date = Date(), offered: Set<String> = []) -> Found? {
        let site = Vault.registrable(host)
        guard !site.isEmpty else { return nil }
        for item in mail.sorted(by: { $0.at > $1.at }) {
            let age = now.timeIntervalSince(item.at)
            let key = "\(item.account ?? ""):\(item.thread ?? ""):\(item.at.timeIntervalSince1970)"
            guard age >= -30, age < fresh, item.unread, !item.junk, !offered.contains(key),
                  MailCodes.belongs(address: item.address, from: item.from, subject: item.subject, to: host),
                  MailLinkWords.says(item.subject + "\n" + item.text) else { continue }
            let links = MailLinkWords.links(html: item.html, text: item.text)
            guard let link = links.first(where: { link in
                let to = link.url.host()?.lowercased() ?? ""
                if Vault.registrable(to) == site { return true }
                // Somewhere else only with a button that says it is the way in.
                return link.score >= 3 && (under(to, signers) || under(to, wrappers))
            }) else { continue }
            let from = item.from.isEmpty ? site : item.from
            return Found(url: link.url, site: site, from: from, key: key, thread: item.thread, account: item.account)
        }
        return nil
    }

    /// Links offered this launch, and how often: once, and once again if
    /// another notice took the corner before it was answered.
    @MainActor static var offered: [String: Int] = [:]
    /// Taken: Open was pressed, never offered again.
    @MainActor static var opened = Set<String>()
    /// The corner's offer now, to tell it from another notice there.
    @MainActor static var showing: String?

    /// Mail as last read, and when: a tab switch reads the store only once
    /// mail changed or a few seconds went by.
    @MainActor private static var read: (mail: [Mailed], changed: Int, at: Date)?

    /// Mail changed, or another page came in front (a tab, a window, Yab
    /// itself): the page in front of the key window, if a fresh mail from
    /// its site carries a way in, gets the corner's offer. A mail that came
    /// while you were elsewhere is offered when you come back to its site.
    @MainActor static func look() {
        _ = watching
        let center = MailCenter.shared
        let fake = MailCodes.fakeMail.withLock { $0 }
        // Only where someone is looking: Yab in front, its key window.
        guard center.connected || fake != nil, NSApp.isActive else { return }
        for browser in BrowserWindows.shared.browsers {
            guard browser.prefs.mailCodes, let tab = browser.active, browser.offersAutofill(tab),
                  let address = tab.address, secure(address),
                  let host = browser.curtain.host(of: address) else { continue }
            let recent: [Mailed]
            if let fake { recent = fake }
            else if let read, read.changed == center.changed, Date().timeIntervalSince(read.at) < 5 { recent = read.mail }
            else {
                recent = center.recent(minutes: fresh / 60)
                read = (recent, center.changed, Date())
            }
            // Offered before, still unanswered, and the corner says something
            // else now: once more. Shown now, or taken: not again.
            let toaster = browser.toaster
            let done = Set(offered.filter { key, times in
                times >= 2 || opened.contains(key) || (showing == key && toaster.shown && toaster.act == "Open")
            }.keys).union(opened)
            guard let found = found(in: recent, for: host, offered: done) else { continue }
            offered[found.key, default: 0] += 1
            showing = found.key
            let id = tab.id
            toaster.pop("Sign in to \(name(found))", mark: "envelope", stay: stay,
                        undo: { [weak browser] in
                            opened.insert(found.key)
                            browser?.openMailLink(found, in: id)
                        }, act: "Open")
            return
        }
    }

    /// A window coming to the front, and Yab itself: looked at again a beat
    /// later, once the page in front is the one that is shown.
    @MainActor private static let watching: [NSObjectProtocol] = [
        NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification,
    ].map { name in
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { look() } }
        }
    }

    /// Only https pages, as a password is only offered there; a test
    /// world's own pages on this Mac too.
    @MainActor static func secure(_ address: URL) -> Bool {
        if address.scheme?.lowercased() == "https" { return true }
        let host = address.host()?.lowercased() ?? ""
        return Store.testing && (host == "127.0.0.1" || host == "localhost")
    }

    /// A name went out without a password, the first step of signing in by
    /// mail as often as by password, or a password that may bring a mail
    /// about a new device: Mail syncs every 2 seconds for half a minute, so
    /// the link is here as soon as it is sent.
    @MainActor static func awaited(_ tab: Tab) {
        guard let address = tab.address, secure(address) else { return }
        MailCenter.shared.quick(for: 30)
    }

    /// The host is one of these or a name under one: the list of public
    /// suffixes makes some of them suffixes, so their registrable name says
    /// nothing.
    nonisolated static func under(_ host: String, _ names: Set<String>) -> Bool {
        names.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// What the corner calls the site: the sender's name, without "Team"
    /// and the like, else the site's address.
    nonisolated static func name(_ found: Found) -> String {
        var name = found.from.trimmingCharacters(in: .whitespacesAndNewlines)
        for tail in [" Team", " team", " Support", " Accounts", " Account"] where name.hasSuffix(tail) {
            name = String(name.dropLast(tail.count))
        }
        let generic = ["noreply", "no-reply", "no reply", "notifications", "notification", "hello", "support", "team", "accounts"]
        if name.isEmpty || name.contains("@") || name.count > 24 || generic.contains(name.lowercased()) { return found.site }
        return name
    }
}

extension Browser {
    /// Open on the corner's offer: the link, in the tab it was offered for,
    /// while that tab is still on the same site. Once.
    func openMailLink(_ found: MailLinks.Found, in id: Tab.ID) {
        guard let tab = autofillTab(id), let host = curtain.host(of: tab.address),
              Vault.registrable(host) == found.site else { return }
        if tabs.contains(where: { $0.id == id }), activeID != id { select(tab) }
        tab.go(to: found.url)
        if MailCodes.archivesUsed, let thread = found.thread, let account = found.account {
            MailCenter.shared.act(.archive, thread: thread, account: account)
        }
    }
}
