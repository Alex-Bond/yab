import AppKit
import WebKit

extension Notification.Name {
    static let assistantAuthorizationCode = Notification.Name("yab.assistantAuthorizationCode")
}

/// A connector's own OAuth page carries the code the relay just issued.
/// Only the configured relay origin is recognized; Yab still looks up the
/// code on its host account and asks the person before linking anything.
@MainActor
enum AssistantAuthorizationPage {
    private static var seen = Set<String>()
    private static var checking = Set<String>()

    static func arrived(_ tab: Tab, in browser: Browser) {
        guard let url = tab.address else { return }
        let origin = AssistantHost.origin
        guard url.scheme == origin.scheme, url.host() == origin.host(), url.port == origin.port,
              url.path == "/oauth/authorize" || url.path == "/connect" else { return }
        let key = tab.id.uuidString + "|" + url.absoluteString
        guard !seen.contains(key), checking.insert(key).inserted else { return }
        readCode(tab, browser: browser, key: key, attempts: 12)
    }

    private static func readCode(_ tab: Tab, browser: Browser, key: String, attempts: Int) {
        tab.page.run("document.querySelector('.code')?.textContent?.trim()") { result in
            let possible = (try? result.get()) as? String
            Task { @MainActor in
                guard !seen.contains(key) else { checking.remove(key); return }
                guard let code = possible,
                      code.range(of: "^[A-HJ-NP-Z2-9]{4}-[A-HJ-NP-Z2-9]{4}$", options: .regularExpression) != nil else {
                    if attempts > 1, key == tab.id.uuidString + "|" + (tab.address?.absoluteString ?? "") {
                        try? await Task.sleep(for: .milliseconds(250))
                        readCode(tab, browser: browser, key: key, attempts: attempts - 1)
                    } else { checking.remove(key) }
                    return
                }
                seen.insert(key)
                checking.remove(key)
                AssistantConnectIntent.code = code
                browser.openSettings(.assistants)
                NotificationCenter.default.post(name: .assistantAuthorizationCode, object: code)
            }
        }
    }
}
