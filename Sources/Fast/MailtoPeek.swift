import AppKit
import SwiftUI
import WebKit

// A mailto: link clicked on a page: a new mail over it, from Yab's own
// mail, in a peek grown out of the link, the page dimmed underneath and
// left where it was. Its addresses, subject and words are the link's; the
// keyboard is in the words. ⌘↩ sends it and it goes back into the link,
// the corner offering Undo while it waits; esc puts it away, in Kept when
// it is yours, the corner saying so with Open; the same link again brings
// that draft back. ⌘O goes on with it in mail's page.
//
// The mail is mail's own draft (MailDesk.composeOutside), drawn in the
// peek's card (MailtoCard) while mail's page shows it as it stands, so
// ⌘O changes nothing but where it is written.
//
// Only a link clicked: a page that opens mailto: by itself still asks
// (Browser.openElsewhere). With no mail account it is the Mac's mail
// app's, as before.
//
// From another app (Slack, the Finder, a terminal), once Yab is the Mac's
// mail app (Settings › Mail, Default mail app; MailDefault): Yab comes to
// the front in mail's space, the new mail out of the pen as C's is; there
// is no page for it to grow out of. docs/mail.md, Mailto links.

enum MailtoPeek {
    /// The card's width: about mail's page's reading column.
    static let width: CGFloat = 620
}

extension Browser {
    /// A mailto: link clicked on `tab`'s page: true when Yab writes it.
    func mailto(_ url: URL, from tab: Tab) -> Bool {
        guard prefs.usesMail, !MailCenter.shared.accounts.isEmpty, let link = MailtoLink(url) else { return false }
        let made = MailDesk.shared.mail(for: link)
        // Mail's own page: written there, as C writes one.
        if MailPage.isMail(tab.address) {
            MailDesk.shared.compose(made)
            return true
        }
        return presentMailto(made, from: tab)
    }

    /// The mail over the page in front, out of the link last pressed there.
    @discardableResult
    private func presentMailto(_ draft: MailDesk.Draft, from tab: Tab?, yours: Bool = false) -> Bool {
        guard let source = tab ?? active, let view = peekView, view.window != nil else { return false }
        if peeking != nil { closePeek() }
        let desk = MailDesk.shared
        desk.composeOutside(draft, in: self, yours: yours)
        mailtoFrom = source.id
        let host = NSHostingController(rootView: MailtoCard(desk: desk) { [weak view] tall in view?.mail(tall: tall) })
        host.sizingOptions = []
        // As tall as it is written at the card's width, before it is shown.
        let width = min(MailtoPeek.width, max(280, view.bounds.width - 64))
        let tall = host.sizeThatFits(in: CGSize(width: width, height: 4000)).height
        view.present(mail: host.view, owner: host, tall: tall, from: source.builtPage)
        return true
    }

    /// Esc, ⌘W or a click beside it: put away, kept when it is yours.
    func closeMailto() {
        // A thread over the page goes the same ways (MailThreadPeek).
        if threadPeek != nil { return closeThreadPeek() }
        guard mailtoFrom != nil else { return }
        if MailDesk.shared.outside, MailDesk.shared.draft != nil { MailDesk.shared.closeDraft() } else { mailtoClosed() }
    }

    /// ⌘O: on in mail's page, the very draft.
    func keepMailto() {
        guard mailtoFrom != nil else { return }
        mailtoFrom = nil
        MailDesk.shared.keepOutside()
        peekView?.dismiss {}
        showMail()
    }

    /// Sent or closed (MailDesk): back into the link, the page's again.
    func mailtoClosed() {
        guard let id = mailtoFrom else { return }
        mailtoFrom = nil
        let source = tabs.first { $0.id == id }
        peekView?.dismiss(to: source?.builtPage) {}
        if let web = source?.builtPage, id == activeID { web.window?.makeFirstResponder(web) }
    }

    /// A send from over a page taken back (Undo): the mail up over the page
    /// in front again, as it went, a page of mail's space too. False with
    /// mail's own page in front, where it comes back as C's does.
    func mailtoAgain(_ draft: MailDesk.Draft) -> Bool {
        guard let tab = active, !MailPage.isMail(tab.address) else { return false }
        return presentMailto(draft, from: tab, yours: true)
    }
}

extension Browser {
    /// A mailto: link from another app: a new mail in mail's space, a draft
    /// open there kept first. No account to write from: Settings › Mail,
    /// where one is added.
    func mailtoFromElsewhere(_ url: URL) {
        guard let link = MailtoLink(url) else { return }
        guard prefs.usesMail, !MailCenter.shared.accounts.isEmpty else {
            openSettings(.mail)
            return
        }
        if mailtoFrom != nil { closeMailto() }
        let desk = MailDesk.shared
        if desk.draft != nil { desk.closeDraft() }
        enterMail()
        desk.compose(desk.mail(for: link))
    }
}

extension Links {
    /// A mailto: link handed over by macOS: to the window in front, Yab
    /// shown; launched by the link, once its window is made.
    static func takeMail(_ url: URL, tries: Int = 0) {
        guard let browser = Links.browser else {
            if tries < 60 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { takeMail(url, tries: tries + 1) } }
            return
        }
        MainActor.assumeIsolated {
            Headless.show(.person)
            NSApp.activate()
            browser.mailtoFromElsewhere(url)
        }
    }
}

/// Yab as the Mac's mail app: mailto: links from every other app come here.
@MainActor
enum MailDefault {
    private static let probe = URL(string: "mailto:someone@example.com")!

    /// The app mail links open in now, by its name: "Mail" when none is.
    static var current: String {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return "Mail" }
        return FileManager.default.displayName(atPath: handler.path).replacingOccurrences(of: ".app", with: "")
    }

    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send mailto: here; macOS may ask first. `done` on the
    /// main thread, with whether it is so now.
    static func become(_ done: @escaping (Bool) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { _ in
            DispatchQueue.main.async { done(isDefault) }
        }
    }
}
