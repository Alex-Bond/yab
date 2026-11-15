import AppKit
import SwiftUI

// A row of Now about a mail, chosen: its thread over the page you are on,
// in a card that comes as mailto's does (MailtoPeek), the page dimmed under
// it and your space left as it was. Esc, ⌘W or a click beside it puts it
// away, and the row stays in Now, paler, until it is done; Do It, Later and
// Done under the mails are the row's own. ⌘O goes on with the thread in
// mail's space.
//
// In mail's space itself there is no card: the thread opens on mail's page,
// which is right there. A thread not in the store yet, or no page to put it
// over, goes to mail's page too.

struct ThreadPeek {
    let url: URL
    let from: Tab.ID
}

extension Browser {
    /// A row of Now about `url`'s thread, taken.
    func mailRow(_ url: URL, hint: String?) {
        if !inMail, presentThreadPeek(url, hint: hint) { return }
        enterMail(url)
    }

    private func presentThreadPeek(_ url: URL, hint: String?) -> Bool {
        let span = MainBudget.begin("mail.peek"); defer { span?.end() }
        guard let (account, thread) = MailSpaceState.thread(in: url),
              let letter = MailDesk.peekLetter(account: account, thread: thread),
              let source = active, let view = peekView, view.window != nil else { return false }
        if peeking != nil { closePeek() }
        if mailtoFrom != nil { closeMailto() }
        if threadPeek != nil { closeThreadPeek() }
        threadPeek = ThreadPeek(url: url, from: source.id)
        let card = MailThreadPeekCard(subject: letter.subject, messages: letter.messages,
                                      actions: hint.map(hintPeekActions) ?? [], browser: self) { [weak view] tall in
            view?.mail(tall: tall)
        }
        let host = NSHostingController(rootView: card)
        host.sizingOptions = []
        // Its height comes as its parts are laid out (MailThreadPeekCard.report).
        view.present(mail: host.view, owner: host, tall: 420, from: nil)
        return true
    }

    /// Esc, ⌘W, a click beside it, another tab: put away, the page's again.
    func closeThreadPeek() {
        guard let peek = threadPeek else { return }
        threadPeek = nil
        peekView?.dismiss {}
        if peek.from == activeID, let web = active?.builtPage { web.window?.makeFirstResponder(web) }
    }

    /// ⌘O: on in mail's space, the thread open there.
    func keepThreadPeek() {
        guard let peek = threadPeek else { return }
        threadPeek = nil
        peekView?.dismiss {}
        enterMail(peek.url)
    }
}
