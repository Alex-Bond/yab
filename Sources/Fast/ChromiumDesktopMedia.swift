import AppKit
import YabCoreClient

/// desktopCapture.chooseDesktopMedia of an extension on Chromium tabs (CEF
/// patch 0122). Chrome's own picker would open over a tab's concealed window,
/// nobody would see or answer it, and the extension would wait for good
/// (Loom, Screenity, Awesome Screenshot). The engine asks here instead: Yab's
/// share box comes up over the tab, as for a WebKit extension
/// (ExtensionCapture.choose) and for a page's getDisplayMedia, and what is
/// picked goes back in the words of a page's display grant (patch 0052).
/// Chrome registers it as its picker's answer, and the extension's
/// getUserMedia plays it with Chrome's own capture.
@MainActor
enum ChromiumDesktopMedia {
    private struct Pending { let client: YabCoreClient; let tab: Tab; let browser: Browser }
    private static var pending: [String: Pending] = [:]

    static func receive(_ event: YabCoreEvent, from client: YabCoreClient?) -> Bool {
        guard event.name == "extension.desktopMedia" || event.name == "extension.desktopMedia.withdrawn" else { return false }
        guard let client, let token = event.params["request"]?.string, !token.isEmpty, token.count <= 256 else { return true }
        if event.name == "extension.desktopMedia.withdrawn" {
            // cancelChooseDesktopMedia: the box goes, as Chromium's picker does.
            if let old = pending.removeValue(forKey: token), old.client === client { old.browser.answer(old.tab, .no) }
            return true
        }
        let p = event.params
        guard pending[token] == nil else { return true }
        guard let profile = p["profile"]?.string, !profile.isEmpty,
              let id = p["extensionId"]?.string, ChromiumExtensions.validID(id),
              case .array(let asked)? = p["sources"] else { return true }
        func refuse() { reply(client, ["request": .string(token), "extension": .string(id), "profile": .string(profile), "source": .string("")]) }
        let page = p["tab"]?.string.flatMap { remote in ChromiumProcess.shared.livePages.first { $0.remoteID == remote && $0.profile == profile } }
        let browser = (page?.navigationTab?.delegate as? Browser)
            ?? BrowserWindows.shared.browsers.first { ChromiumPersistentProfiles.profile(for: $0) == profile }
        var kinds: Set<SharePicker.Kind> = []
        for kind in asked.compactMap(\.string) {
            switch kind {
            case "tab": kinds.insert(.tabs)
            case "window": kinds.insert(.windows)
            case "screen": kinds.insert(.screens)
            default: break
            }
        }
        // A worker's or an offscreen document's ask has no page: the box goes
        // over the tab in front, as Chromium's goes over its last active window.
        guard let browser, !kinds.isEmpty, let anchor = page?.navigationTab ?? browser.active else { refuse(); return true }
        let name = p["extensionName"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "An extension"
        let sound = p["audio"] == .bool(true)
        pending[token] = Pending(client: client, tab: anchor, browser: browser)
        browser.pickNativeShare(for: name, kinds: kinds, on: anchor, offeringCaller: p["excludeSelf"] != .bool(true)) { params in
            guard let old = pending.removeValue(forKey: token), old.client === client else { return }
            var answer: [String: JSONValue] = ["request": .string(token), "extension": .string(id), "profile": .string(profile)]
            if let params {
                answer.merge(params) { _, new in new }
                // Only a tab's sound can come with it, as in Chromium.
                answer["audio"] = .bool(sound && params["source"] == .string("tab"))
            } else {
                answer["source"] = .string("")
            }
            reply(client, answer)
        }
        return true
    }

    static func disconnected(_ client: YabCoreClient?) {
        for (token, old) in pending where client == nil || old.client === client {
            pending[token] = nil
            old.browser.answer(old.tab, .no)
        }
    }

    private static func reply(_ client: YabCoreClient, _ params: [String: JSONValue]) {
        guard ChromiumProcess.shared.isCurrent(client) else { return }
        Task { _ = try? await client.request("extension.desktopMedia.reply", params: params) }
    }

    static var benchState: [String] { Array(pending.keys) }
}

extension Browser {
    /// Yab's share box for an extension's chooseDesktopMedia on Chromium
    /// tabs, as pickShare shows it for a WebKit extension; `done` with the
    /// source in the engine's words (Share.nativeSource), or nil for No, a
    /// WebKit tab, or a window or screen Yab can't see without Screen
    /// Recording.
    func pickNativeShare(for name: String, kinds: Set<SharePicker.Kind>, on tab: Tab, offeringCaller: Bool,
                         done: @escaping ([String: JSONValue]?) -> Void) {
        let picker = SharePicker(token: UUID().uuidString, frame: nil, host: name, audio: false)
        picker.kinds = kinds
        picker.offersSystem = false
        picker.fill(self, caller: tab, offeringCaller: offeringCaller)
        if !onScreen(tab.id) { select(tab) }
        ask(PageAsk(kind: .share(picker), host: name), on: tab) { [weak self] reply, _ in
            guard let self, case .yes = reply, let source = picker.chosen?.source else { return done(nil) }
            done(Share.nativeSource(source, in: self, sees: picker.sees))
        }
    }
}
