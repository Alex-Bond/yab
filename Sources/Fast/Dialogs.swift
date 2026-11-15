import AppKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them, and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows,
// except alert, confirm and prompt from a tab's page, which are asked in the
// card of yab's own (Asks.swift); the sheet is left for pages that have no tab.

extension Browser {
    // MARK: - alert, confirm, prompt

    func page(_ page: any PageHandle, dialog: PageDialog,
              reply: @escaping @MainActor (PageDialogReply) -> Void) {
        switch dialog.kind {
        case .beforeUnload:
            Leaving.asked(page, by: self, host: Dialogs.host(of: dialog.origin)) { reply($0 ? .accept(nil) : .cancel) }
        case .alert:
            showPageAlert(page, message: dialog.message, origin: dialog.origin) { reply(.accept(nil)) }
        case .confirm:
            showPageConfirm(page, message: dialog.message, origin: dialog.origin) { reply($0 ? .accept(nil) : .cancel) }
        case .prompt:
            showPagePrompt(page, prompt: dialog.message, defaultText: dialog.defaultText, origin: dialog.origin) {
                reply($0.map { .accept($0) } ?? .cancel)
            }
        }
    }

    func page(_ page: any PageHandle, chooseFiles picker: PageFilePicker,
              reply: @escaping @MainActor ([URL]?) -> Void) {
        showPageFiles(page, parameters: picker, completionHandler: reply)
    }

    func showPageAlert(_ webView: NSView, owner: Tab? = nil, message: String, origin: PageOrigin,
                       completionHandler: @escaping () -> Void) {
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }), AgentPage.answersDialog(tab) {
            AgentPage.alerts[ObjectIdentifier(tab), default: []].append(message)
            completionHandler()
            return
        }
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }) {
            ExtensionDebugger.shared.dialogOpening(tab, kind: "alert", message: message, defaultPrompt: "")
            ask(PageAsk(kind: .alert, host: Dialogs.host(of: origin), message: message), on: tab) { _, _ in completionHandler() }
            return
        }
        let alert = Dialogs.alert(from: origin, saying: message)
        alert.addButton(withTitle: "OK")
        Dialogs.show(alert, over: webView) { _ in completionHandler() }
    }

    func showPageConfirm(_ webView: NSView, owner: Tab? = nil, message: String, origin: PageOrigin,
                         completionHandler: @escaping (Bool) -> Void) {
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }), AgentPage.answersDialog(tab) {
            AgentPage.hold(tab, AgentPage.Asked(kind: "confirm", message: message, text: "") { yes, _ in completionHandler(yes) }) { [weak self, weak tab] in
                guard let self, let tab else { completionHandler(false); return }
                self.ask(PageAsk(kind: .confirm, host: Dialogs.host(of: origin), message: message), on: tab) { reply, _ in
                    if case .yes = reply { completionHandler(true) } else { completionHandler(false) }
                }
            }
            return
        }
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }) {
            ExtensionDebugger.shared.dialogOpening(tab, kind: "confirm", message: message, defaultPrompt: "")
            ask(PageAsk(kind: .confirm, host: Dialogs.host(of: origin), message: message), on: tab) { reply, _ in
                if case .yes = reply { completionHandler(true) } else { completionHandler(false) }
            }
            return
        }
        let alert = Dialogs.alert(from: origin, saying: message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn)
        }
    }

    func showPagePrompt(_ webView: NSView, owner: Tab? = nil, prompt: String, defaultText: String?, origin: PageOrigin,
                        completionHandler: @escaping (String?) -> Void) {
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }), AgentPage.answersDialog(tab) {
            AgentPage.hold(tab, AgentPage.Asked(kind: "prompt", message: prompt, text: defaultText ?? "") { yes, text in
                completionHandler(yes ? (text ?? defaultText ?? "") : nil)
            }) { [weak self, weak tab] in
                guard let self, let tab else { completionHandler(nil); return }
                self.ask(PageAsk(kind: .prompt, host: Dialogs.host(of: origin), message: prompt, text: defaultText ?? ""), on: tab) { reply, _ in
                    if case .yes(let text) = reply { completionHandler(text ?? "") } else { completionHandler(nil) }
                }
            }
            return
        }
        if let tab = owner ?? (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }) {
            ExtensionDebugger.shared.dialogOpening(tab, kind: "prompt", message: prompt, defaultPrompt: defaultText ?? "")
            ask(PageAsk(kind: .prompt, host: Dialogs.host(of: origin), message: prompt, text: defaultText ?? ""), on: tab) { reply, _ in
                if case .yes(let text) = reply { completionHandler(text ?? "") } else { completionHandler(nil) }
            }
            return
        }
        let alert = Dialogs.alert(from: origin, saying: prompt)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        Dialogs.show(alert, over: webView) { answer in
            completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    // MARK: - choosing a file

    func showPageFiles(_ webView: NSView, parameters: PageFilePicker,
                       completionHandler: @escaping ([URL]?) -> Void) {
        guard parameters.lifetime?.isActive != false else { return }
        if let name = parameters.saveName {
            guard let window = Dialogs.window(for: webView) else { completionHandler(nil); return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = name
            panel.canCreateDirectories = true
            parameters.lifetime?.whenCancelled { [weak panel] in panel?.cancel(nil) }
            panel.beginSheetModal(for: window) { response in
                guard parameters.lifetime?.isActive != false else { return }
                completionHandler(response == .OK ? panel.url.map { [$0] } : nil)
            }
            return
        }
        // Files an agent was allowed to give this page: handed over, no
        // picker.
        if let tab = tabs.first(where: { $0.builtPage === webView }), let given = tab.uploading, given.until > Date() {
            tab.uploading = nil
            completionHandler(parameters.allowsMultiple ? given.files : Array(given.files.prefix(1)))
            return
        }
        // An agent's own tab, nobody at it: the open panel would wait over
        // a window nobody looks at (or none, with Yab hidden), and the agent
        // can't use it. It is closed, and the agent told the way that works
        // (feedback #141: it asked the person to pick the file instead).
        if let tab = tabs.first(where: { $0.builtPage === webView }), AgentPage.answers(tab) || Dialogs.agentClicked(tab) {
            AgentPage.alerts[ObjectIdentifier(tab), default: []].append(AgentPage.pickerClosed)
            completionHandler(nil)
            return
        }
        let open = { [weak webView] (folder: URL?) in
            guard parameters.lifetime?.isActive != false else { return }
            let panel = NSOpenPanel()
            parameters.lifetime?.whenCancelled { [weak panel] in panel?.cancel(nil) }
            let fileHost = self.tabs.first(where: { $0.builtPage === webView })?.address?.host() ?? ""
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultiple
            panel.resolvesAliases = true
            panel.directoryURL = folder ?? Browser.lastFileFolder(fileHost)
            let finish: (NSApplication.ModalResponse) -> Void = { answer in
                guard parameters.lifetime?.isActive != false else { return }
                if answer == .OK, let first = panel.urls.first { Browser.rememberFileFolder(first, host: fileHost) }
                completionHandler(answer == .OK ? panel.urls : nil)
            }
            if let webView, let window = Dialogs.window(for: webView) {
                panel.beginSheetModal(for: window, completionHandler: finish)
            } else {
                finish(panel.runModal())
            }
        }
        // The Files place keeps this open-panel question until selection.
        if let tab = tabs.first(where: { $0.builtPage === webView }),
           offerFiles(tab, parameters, panel: open, answer: completionHandler) {
            return
        }
        open(nil)
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func page(_ page: any PageHandle, authenticate challenge: PageAuthentication,
              reply: @escaping @MainActor (PageAuthenticationReply) -> Void) {
        signIn(page, challenge, reply)
    }

    func page(_ page: any PageHandle, rejected certificate: PageCertificate) {
        let host = certificate.host
        // Only the page asked for gets a question; bad subresources stay refused.
        guard let tab = tab(owning: page),
              let asked = [certificate.failingURL, tab.pending, page.url, tab.address].compactMap({ $0 }).first(where: {
                  $0.scheme?.lowercased() == "https" && $0.host().map(CertificateException.hostName) == host
                      && ($0.port ?? 443) == certificate.port
              }) else { return }
        if retryHTTP(tab, failed: asked, code: NSURLErrorServerCertificateUntrusted) { return }
        // A rejected redirect may not have committed its endpoint yet.
        if certificate.failingURL != nil { tab.setAddressOptimistically(asked) }
        if let other = WWWRetry.claim(asked, code: NSURLErrorServerCertificateUntrusted) {
            lookAtOtherName(tab, failed: asked, other: other) { [weak tab] in
                tab?.untrusted = Untrusted(host: host, url: asked, exception: certificate.exception,
                                           why: certificate.why, names: certificate.names)
            }
            return
        }
        tab.untrusted = Untrusted(host: host, url: asked, exception: certificate.exception,
                                 why: certificate.why, names: certificate.names)
    }

    /// A site behind a name and a password, a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    func signIn(
        _ webView: NSView,
        _ challenge: PageAuthentication,
        _ completionHandler: @escaping @MainActor (PageAuthenticationReply) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancel)
            return
        }
        let space = challenge
        let host = space.host.lowercased()
        // This Mac itself is never read on the way, whatever the scheme.
        let clear = space.scheme?.lowercased() == "http" && !Dialogs.isLoopback(host)
        // Kept a moment ago and turned away: not a password worth keeping.
        if challenge.previousFailureCount > 0, let user = Dialogs.justKept.removeValue(forKey: host) {
            Vault.forget(host: host, user: user)
        }
        if let tab = (webView as? any PageHandle).flatMap({ self.tab(owning: $0) }) {
            var question = PageAsk(kind: .signIn(space.realm ?? ""), host: host)
            // A name in the address comes as a try with an empty password:
            // no one has got anything wrong yet.
            question.failed = challenge.previousFailureCount > 0
                && !challenge.proposedPasswordIsEmpty
            question.clear = clear
            // What Passwords keeps for this very host fills the card, so a
            // Return signs in; a password kept from https never goes to a
            // site asking over plain http.
            // This Space's first, as the list under a sign-in box has them.
            let here = loginSpace(tab)
            if !question.failed, let login = SuggestRows.hereFirst(Vault.logins(for: host), here: here, spaces: loginSpaceNames)
                .first(where: { !clear || $0.clear }) {
                question.text = login.user
                question.secret = login.password
                question.kept = true
            } else if let user = challenge.proposedUser, !user.isEmpty {
                // The name WebKit has already, from the address (a name@
                // before the host) or the try just refused.
                question.text = user
            }
            ask(question, on: tab) { reply, answered in
                guard case .yes = reply else {
                    completionHandler(.cancel)
                    return
                }
                if answered.ticked, !answered.kept, !answered.secret.isEmpty {
                    Vault.save(host: host, user: answered.text, password: answered.secret, used: Date(), clear: clear, space: here)
                    Dialogs.justKept[host] = answered.text
                }
                completionHandler(.credential(user: answered.text, password: answered.secret))
            }
            return
        }
        // A page with no tab of its own: the system's sheet, as before.
        let alert = NSAlert()
        alert.messageText = "\(space.host) needs a name and password"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "Sign in to continue"
        // A name in the address comes as a try with an empty password: no
        // one has got anything wrong yet.
        if challenge.previousFailureCount > 0, !challenge.proposedPasswordIsEmpty {
            alert.informativeText += "\nWrong name or password, try again"
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        // The name WebKit has for it already, from the address (a name@
        // before the host) or the try that was refused: filled in, and the
        // password is what is left to type.
        let known = challenge.proposedUser ?? ""
        name.stringValue = known
        alert.window.initialFirstResponder = known.isEmpty ? name : pass

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancel)
                return
            }
            completionHandler(.credential(user: name.stringValue, password: pass.stringValue))
        }
    }

    // MARK: - a page whose process went away

    func page(_ page: any PageHandle, ended reason: PageEnd?) {
        guard let tab = tab(owning: page) else { return }
        if page.engine == .chromium { dropAsks(tab) }
        if !tab.shy { FeedbackDiagnostics.shared.record(.webProcessTerminated, reason: reason) }
        // Where it was, for when it is loaded again.
        tab.notePlace()
        // Out in the little window, it would sit there black.
        if floating == tab.id { land() }
        // The system's Picture-in-Picture window went with the process.
        tab.pictureInPicture = false
        // Whatever ended it, it is no longer a page that won't answer, and
        // the question about it is moot (Deaf.swift).
        tab.deaf = nil
        if tab.asks.first?.kind == .stuck { dismissAsk(tab) }
        // Chrome's SadTabHelper owns renderer termination in a Chrome-style
        // CEF view. Keep its sad tab visible until the person reloads. The
        // WebKit recovery policy below must not navigate that view away.
        if page.engine == .chromium {
            stuck.ending.remove(tab.id)
            stuck.outgrown.remove(tab.id)
            stuck.halting.remove(tab.id)
            tab.stale = false
            tab.staleReason = nil
            return
        }
        // Ended by the browser itself, for being stuck or too big: loaded
        // again at once, wherever the tab is, and not counted as a crash.
        if stuck.ending.remove(tab.id) != nil {
            tab.stale = false
            tab.recoverFromCrash(reason: reason)
            return
        }
        // Grown too big again after being loaded again for it (Stuck.swift's
        // `lighten`): stopped it stays.
        if stuck.outgrown.remove(tab.id) != nil {
            tab.stale = false
            tab.failure = StuckWatch.memoryStopped
            return
        }
        // Stopped by you while stuck (unstick): stopped it stays.
        if stuck.halting.remove(tab.id) != nil {
            tab.stale = false
            tab.failure = "This page stopped responding"
            return
        }
        // The rest a tenth of a second on, with every other page that
        // ended in that moment (PageEnds).
        if stuck.ends.heard == nil {
            stuck.ends.heard = { [weak self] batch in self?.pagesEnded(batch) }
        }
        stuck.ends.ended(tab, reason: reason)
    }

    /// A page that crashes as soon as it loads, loaded again each time,
    /// crashed hundreds of times a minute, every crash a process started
    /// and its memory taken. The third crash within a minute stops there:
    /// the page says so, out of memory or crashing, and Reload is yours to
    /// press. Pages that went together went for something they share, and
    /// none of them counts.
    private func pagesEnded(_ batch: [(end: PageEnds.Ended, again: Bool)]) {
        for (end, again) in batch {
            guard let tab = end.tab, !tab.gone, !tab.asleep else { continue }
            if again {
                tab.stale = false
                tab.failure = (end.reason ?? .crash).again
                continue
            }
            // In front of you: straight back, a reload beats a white page with a
            // button on it. Behind another tab: the moment you come back to it.
            if tab.id == activeID, !tab.isBlank {
                tab.recoverFromCrash(reason: end.reason)
            } else {
                tab.stale = true
                tab.staleReason = end.reason
            }
        }
    }
}

/// A site whose certificate this Mac doesn't trust, and what can be said of
/// why, for the page that stands in the tab instead of it.
struct Untrusted: Equatable {
    let host: String
    let url: URL
    let exception: CertificateException?
    /// Why, in a sentence.
    let why: String
    /// Whom the certificate names, and who signed it.
    let names: String
}

enum Dialogs {
    /// An agent's click just now, in a tab of yours, and not one of yours
    /// since: the picker it opened is the agent's, not yours.
    @MainActor static func agentClicked(_ tab: Tab) -> Bool {
        let feed = AgentFeed.shared
        guard let act = feed.last[tab.id], Date().timeIntervalSince(act.at) < 3 else { return false }
        return feed.touched[tab.id].map { $0 < act.at } ?? true
    }

    /// A sign-in just kept in Passwords, by host, until the site says
    /// whether it worked.
    static var justKept: [String: String] = [:]

    /// A site's certificate checked on the main thread, as before
    /// (Browser.trust): YAB_TRUST_MAIN=1, for an A/B.
    static let trustOnMain = ProcessInfo.processInfo.environment["YAB_TRUST_MAIN"] == "1"

    /// Who is asking, as the pill names it.
    static func host(of origin: PageOrigin) -> String {
        let host = origin.host
        return host.isEmpty ? "This page" : host
    }

    static func alert(from origin: PageOrigin, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = origin.host
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now.
    static func window(for webView: NSView) -> NSWindow? {
        webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
    }

    static func show(
        _ alert: NSAlert,
        over webView: NSView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }

    /// This Mac itself: a certificate here can only have been made here.
    /// Only the names that can't mean anything else: localhost, and the
    /// loopback addresses written as addresses, four numbers and nothing
    /// more, so 127.0.0.1.example.com is a website like any other.
    static func isLoopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return parts[0] == "127"
    }
}
