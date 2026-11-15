import YabStore
import AppKit
import LocalAuthentication
import Security
import WebKit

/// A connected password manager's unlock password: kept in this Mac's
/// keychain only, read by Yab alone, and typed by Yab into the manager's
/// own unlock page when an agent finds it locked. The model never sees it.
enum ManagerUnlock {
    /// One item a manager: service and account, this device only, in the
    /// data protection keychain where the build is entitled to it. A test
    /// world keeps its own, apart from the person's.
    static var service: String {
        "Yab · password manager unlock" + (Store.testing ? " · \(Store.folder.lastPathComponent)" : "")
    }

    static func query(_ id: String, protected: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        query[kSecUseDataProtectionKeychain as String] = protected
        // Never a password window: an item this build can't read is not there.
        let quiet = LAContext()
        quiet.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = quiet
        return query
    }

    /// Saved, then read back: true only when the read gives the same back.
    /// A build not entitled to the data protection keychain (a test run)
    /// keeps it in the login keychain, this device only all the same.
    static func save(_ id: String, _ password: String) -> Bool {
        guard !password.isEmpty else { return false }
        for protected in [true, false] {
            let base = query(id, protected: protected)
            Keychain.delete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data(password.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            add[kSecAttrLabel as String] = "Yab: \(PasswordManagers.name(id)) unlock password"
            let status = Keychain.add(add as CFDictionary, nil)
            if status == errSecMissingEntitlement { continue }
            guard status == errSecSuccess else { return false }
            return read(id) == password
        }
        return false
    }

    enum Read: Equatable { case found(String), missing, locked }

    /// The password, or why there is none: a locked Mac reads as locked.
    static func fetch(_ id: String) -> Read {
        for protected in [true, false] {
            var ask = query(id, protected: protected)
            ask[kSecReturnData as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            var found: AnyObject?
            let status = Keychain.copyMatching(ask as CFDictionary, &found)
            if status == errSecSuccess, let data = found as? Data, let text = String(data: data, encoding: .utf8) { return .found(text) }
            if status == errSecInteractionNotAllowed { return .locked }
        }
        return .missing
    }

    static func read(_ id: String) -> String? {
        if case .found(let text) = fetch(id) { return text }
        return nil
    }

    /// Whether one is kept, without reading it.
    static func has(_ id: String) -> Bool {
        for protected in [true, false] {
            var ask = query(id, protected: protected)
            ask[kSecReturnAttributes as String] = true
            ask[kSecMatchLimit as String] = kSecMatchLimitOne
            if Keychain.copyMatching(ask as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    static func forget(_ id: String) {
        for protected in [true, false] { Keychain.delete(query(id, protected: protected) as CFDictionary) }
    }

    // MARK: - the unlock

    enum Outcome: Equatable { case unlocked, notUnlocked, noField, notRunning }

    /// Is a password box showing on the page.
    static let boxScript = """
    return [...document.querySelectorAll('input[type=password]')].some(e => {
      const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.disabled;
    });
    """

    /// The password into the first password box that shows, set as a
    /// person's typing sets it, never written into the source: it comes in
    /// as an argument, and nothing of it comes back.
    static let fillScript = """
    const deadline = Date.now() + 8000;
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.disabled && !e.readOnly; };
    let field = null;
    while (Date.now() < deadline) {
      field = [...document.querySelectorAll('input[type=password]')].find(shown) || null;
      if (field) break;
      await new Promise(done => setTimeout(done, 200));
    }
    if (!field) return 'no-field';
    field.focus();
    Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, secret);
    field.dispatchEvent(new Event('input', { bubbles: true }));
    field.dispatchEvent(new Event('change', { bubbles: true }));
    return 'filled';
    """

    /// Whether the manager is locked, seen on its own unlock page in a
    /// background tab: a password box there is a lock. Only read, never
    /// typed into; the tab closes. Nil when the page couldn't be read.
    @MainActor static func peekLocked(_ id: String, in browser: Browser, house: (Tab) -> Void) async -> Bool? {
        guard let item = PasswordManagers.installed(id), item.enabled,
              let context = Extensions.here.contexts[item.id],
              let page = PasswordManagers.provider(id)?.unlockPage else { return nil }
        let address = context.baseURL.appendingPathComponent(page)
        let tab = browser.benchOpen(address)
        guard let web = tab.webKitOnly("Legacy password-manager unlock") else { browser.close(tab); return nil }
        house(tab)
        defer { browser.close(tab) }
        for _ in 0..<40 {
            if !web.isLoading, web.url?.absoluteString.hasPrefix(address.absoluteString) == true { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Its app draws a beat after it loads: a box that comes is a lock.
        var seen: Bool?
        for _ in 0..<12 {
            let box = try? await web.callAsyncJavaScript(boxScript, arguments: [:], in: nil, contentWorld: .page)
            if box as? Bool == true { return true }
            if box != nil { seen = false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return seen
    }

    /// Opens the manager's unlock page in a background tab of the agent's,
    /// types the password there and presses Return, then waits up to 6 s
    /// for the box to go. One try; the tab closes either way.
    @MainActor static func run(_ id: String, secret: String, in browser: Browser, session: String?, house: (Tab) -> Void,
                               done: @escaping @MainActor (Outcome) -> Void) {
        guard PasswordManagers.yabMayUnlock(id), let item = PasswordManagers.installed(id), item.enabled,
              let context = Extensions.here.contexts[item.id],
              let page = PasswordManagers.provider(id)?.unlockPage else { done(.notRunning); return }
        let address = context.baseURL.appendingPathComponent(page)
        let tab = browser.benchOpen(address)
        guard let web = tab.webKitOnly("Legacy password-manager unlock") else {
            browser.close(tab)
            done(.notRunning)
            return
        }
        tab.agent = session ?? Agents.script
        house(tab)
        func finish(_ outcome: Outcome) {
            browser.close(tab)
            done(outcome)
        }
        Task { @MainActor in
            for _ in 0..<40 {
                if !web.isLoading, web.url?.absoluteString.hasPrefix(address.absoluteString) == true { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            // Only on the extension's own origin.
            guard web.url?.host() == context.baseURL.host() else { finish(.noField); return }
            finish(await enter(secret, into: web))
        }
    }

    /// The password typed into a page of the manager's that shows its box,
    /// Return pressed, then up to 6 s for the box to go.
    @MainActor static func enter(_ secret: String, into web: WKWebView) async -> Outcome {
        let filled = try? await web.callAsyncJavaScript(fillScript, arguments: ["secret": secret], in: nil, contentWorld: .page)
        guard filled as? String == "filled" else { return .noField }
        _ = web.webKitAgentPress("Enter")
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(250))
            let box = try? await web.callAsyncJavaScript(boxScript, arguments: [:], in: nil, contentWorld: .page)
            if box as? Bool == false { return .unlocked }
        }
        return .notUnlocked
    }

    /// Its lock screen, and nothing else with a password box: one box, and
    /// an Unlock button or a lock route, and no button that exports,
    /// deletes or changes. Typed into, a password box elsewhere in a
    /// manager (an export's confirmation) would do that thing.
    static let lockScreenScript = """
    const shown = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && !e.disabled && !e.readOnly; };
    const boxes = [...document.querySelectorAll('input[type=password]')].filter(shown);
    if (boxes.length !== 1) return false;
    const said = [...document.querySelectorAll('button,[role=button],input[type=submit]')].filter(shown)
      .map(b => (b.innerText || b.value || b.getAttribute('aria-label') || '').toLowerCase());
    if (said.some(t => /export|delete|change|save|create/.test(t))) return false;
    return /lock/.test((location.hash + location.pathname).toLowerCase()) || said.some(t => /unlock/.test(t));
    """

    /// Whether the page shows the manager's lock screen within `seconds`.
    @MainActor static func lockScreen(_ web: WKWebView, seconds: Double) async -> Bool {
        for _ in 0..<max(1, Int(seconds * 4)) {
            if (try? await web.callAsyncJavaScript(lockScreenScript, arguments: [:], in: nil, contentWorld: .page)) as? Bool == true { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    /// Unlocked out of sight, for the person (ManagerKeep): the unlock page
    /// in a page of its own, in no tab, seen in Yab's room off every screen.
    /// The password is read only once its lock screen shows; no lock screen,
    /// nothing typed (.noField: unlocked already, or signed out).
    @MainActor static func hidden(_ id: String, secret: @MainActor () async -> String?) async -> Outcome {
        guard PasswordManagers.yabMayUnlock(id), let item = PasswordManagers.installed(id), item.enabled,
              let context = Extensions.here.contexts[item.id], let configuration = context.webViewConfiguration,
              let page = PasswordManagers.provider(id)?.unlockPage else { return .notRunning }
        let address = context.baseURL.appendingPathComponent(page)
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        Bench.shared.keepSharing(web)
        defer {
            web.stopLoading()
            web.removeFromSuperview()
        }
        web.load(URLRequest(url: address))
        for _ in 0..<40 {
            if !web.isLoading, web.url?.absoluteString.hasPrefix(address.absoluteString) == true { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard web.url?.host() == context.baseURL.host(), await lockScreen(web, seconds: 4) else { return .noField }
        guard let secret = await secret() else { return .noField }
        return await enter(secret, into: web)
    }

    /// After an unlock, the open pages with a sign-in told they are seen
    /// again, as switching to their tab tells them: NordPass's pages ask its
    /// worker for its whole state then (synco-redux, resyncOnFocus), as a
    /// reload would, should a change have passed them by. A moment after,
    /// for the manager's worker to have the change.
    @MainActor static func nudge() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            MainActor.assumeIsolated {
                for browser in BrowserWindows.shared.browsers {
                    for tab in browser.tabs where !tab.shy {
                        guard let web = tab.webKitOnly("WebKit password manager context", build: false), web.url?.scheme?.hasPrefix("http") == true else { continue }
                        web.evaluateJavaScript("""
                            if (document.visibilityState === 'visible' && document.querySelector('input[type=password],input[type=email],input[autocomplete~=username]'))
                              document.dispatchEvent(new Event('visibilitychange'));
                            """, in: nil, in: .page, completionHandler: nil)
                    }
                }
            }
        }
    }
}
