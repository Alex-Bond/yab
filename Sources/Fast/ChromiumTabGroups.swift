import AppKit
import YabCoreClient

/// What Chrome's extensions see as a window: a Yab window's Chromium pages,
/// per profile, in the column's order, the one on screen active. Without it
/// each page is a window of its own, since each has a concealed native one.
/// Pages not built yet are not listed: Chrome has nothing for them.
@MainActor
final class ChromiumTabGroups {
    static let shared = ChromiumTabGroups()
    private var timer: Timer?
    private var sent: [String: [String]] = [:]

    func start() {
        guard timer == nil else { return }
        sent = [:]
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { ChromiumTabGroups.shared.sync() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func sync() {
        guard let core = ChromiumProcess.shared.connectedClient else {
            sent = [:]; timer?.invalidate(); timer = nil
            return
        }
        for browser in BrowserWindows.shared.browsers {
            var byProfile: [String: [String]] = [:]
            var active: [String: String] = [:]
            for tab in browser.tabs + browser.parkedTabs where !tab.shy {
                guard let page = tab.builtPage as? ChromiumPage, let remote = page.remoteID else { continue }
                byProfile[page.profile, default: []].append(remote)
                if tab.id == browser.activeID { active[page.profile] = remote }
            }
            for (profile, tabs) in byProfile {
                let key = "\(ObjectIdentifier(browser))/\(profile)"
                let shape = tabs + ["|", active[profile] ?? ""]
                guard sent[key] != shape else { continue }
                sent[key] = shape
                let params: [String: JSONValue] = ["tabs": .array(tabs.map { .string($0) }), "active": .string(active[profile] ?? "")]
                Task { _ = try? await core.request("tabs.group", params: params) }
            }
        }
    }
}
