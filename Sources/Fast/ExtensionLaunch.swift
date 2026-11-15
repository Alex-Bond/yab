import Foundation

// What each extension needs when Yab starts, as Chrome decides it.
//
// Chrome starts an extension's worker at launch only when it listens for
// the browser starting; otherwise the worker sleeps until an event it
// listens for comes. WebKit can't be told that: every extension context it
// loads starts its worker at once, to say runtime.onStartup in the
// controller's first five seconds and runtime.onInstalled after
// (WebExtensionContext::loadBackgroundWebViewDuringLoad), so a worker can
// only be kept asleep by not loading its extension. An extension's content
// scripts and its declarativeNetRequest rules hold only while it is loaded,
// so one with either is loaded at launch, first, as before; so is one
// whose worker must run every launch to have its menus or alarms (WebKit
// keeps neither across a restart), and one whose worker listens for tabs,
// windows, navigation or the browser starting. What remains is woken by
// its first use: its button pressed, its options or a page of its own
// opened, Settings showing it.
//
// What the worker listens for is what it told Yab in its last run (the
// shim's background.listeners), kept by version in listeners.json beside
// installed.json; an extension not heard from at this version is loaded at
// launch, which hears it. See docs/lazy-launch.md.

enum ExtensionLaunch {
    /// When an extension is loaded as Yab starts.
    enum Need: String, Equatable {
        /// At launch, before the rest: its scripts and rules act on the
        /// first page.
        case first
        /// At launch, after those.
        case launch
        /// On its first use.
        case onUse
    }

    /// What its manifest says that matters here.
    struct Facts: Equatable {
        var version = ""
        var background = false
        var contentScripts = false
        var rules = false
        var permissions: Set<String> = []
        var commands = false
        var external = false
    }

    nonisolated static func facts(_ manifest: [String: Any]) -> Facts {
        var facts = Facts()
        facts.version = manifest["version"] as? String ?? ""
        let background = manifest["background"] as? [String: Any]
        facts.background = background?["service_worker"] != nil || background?["scripts"] != nil || background?["page"] != nil
        facts.contentScripts = !((manifest["content_scripts"] as? [Any]) ?? []).isEmpty
        let resources = ((manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]]) ?? []
        facts.rules = resources.contains { $0["enabled"] as? Bool ?? true }
        facts.permissions = Set(((manifest["permissions"] as? [Any]) ?? []).compactMap { $0 as? String })
        // A key of its own beyond the button's: kept to its worker, which
        // must be there to hear it.
        let commands = (manifest["commands"] as? [String: Any]) ?? [:]
        facts.commands = commands.keys.contains { !$0.hasPrefix("_execute_") }
        facts.external = manifest["externally_connectable"] != nil
        return facts
    }

    /// Whether the extension in `folder` blocks requests with lists of its
    /// own, as an ad blocker does: rule files of 64 KB and more. A password
    /// manager's one header rule doesn't make it one. Only file sizes are
    /// read, at launch.
    nonisolated static func blocks(in folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let resources = ((manifest["declarative_net_request"] as? [String: Any])?["rule_resources"] as? [[String: Any]]) ?? []
        let bytes = resources.filter { $0["enabled"] as? Bool ?? true }.compactMap { $0["path"] as? String }.reduce(0) { sum, path in
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(path).path)[.size] as? Int) ?? 0
            return sum + size
        }
        return bytes >= 64 * 1024
    }

    /// Whether the extension in `folder` acts on pages as they load: content
    /// scripts, a wallet's provider among them, or an ad blocker's lists.
    /// A space's own sign-in's pages wait for these (Extensions.holdSignInPages).
    nonisolated static func actsOnPages(in folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return facts(manifest).contentScripts || blocks(in: folder)
    }

    /// Events a worker can sleep through: each comes only from something
    /// Yab wakes it for first (its button, its own pages, Settings).
    nonisolated static let sleepable: Set<String> = [
        "action.onClicked", "browserAction.onClicked", "pageAction.onClicked",
        "runtime.onInstalled", "runtime.onMessage", "runtime.onConnect", "runtime.onSuspend",
        "runtime.onUpdateAvailable", "storage.onChanged", "permissions.onAdded", "permissions.onRemoved",
        "management.onEnabled", "management.onDisabled", "management.onInstalled", "management.onUninstalled",
    ]

    /// Permissions whose work goes on with nothing pressed: dynamic content
    /// scripts and rules, requests, menus and alarms a worker sets each
    /// launch, proxies, and so on.
    nonisolated static let busy: Set<String> = [
        "scripting", "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback",
        "webRequest", "webRequestBlocking", "webRequestAuthProvider", "proxy", "contextMenus", "menus", "alarms",
        "idle", "notifications", "downloads", "cookies", "tabGroups", "history", "bookmarks", "topSites", "sessions",
        "offscreen", "gcm", "pushMessaging", "power", "system.display", "debugger", "userScripts",
    ]

    /// When `facts`'s extension is loaded, given the events its worker
    /// listened for in its last run at this version (nil: not heard), and
    /// why, for the bench and the docs.
    nonisolated static func need(_ facts: Facts, heard: [String]?, openPage: Bool = false) -> (need: Need, why: String) {
        if facts.contentScripts { return (.first, "content scripts") }
        if facts.rules { return (.first, "network rules") }
        guard facts.background else { return (.launch, "no worker") }
        if openPage { return (.launch, "a page of its own is open") }
        if let busy = facts.permissions.intersection(busy).sorted().first { return (.launch, busy) }
        if facts.commands { return (.launch, "keyboard commands") }
        if facts.external { return (.launch, "other extensions and sites call it") }
        guard let heard else { return (.launch, "not heard from at this version") }
        if let other = heard.sorted().first(where: { !sleepable.contains($0) }) { return (.launch, other) }
        return (.onUse, "only its button and its own pages")
    }

    // MARK: - what each worker listened for

    struct Heard: Codable, Equatable {
        var version: String
        var events: [String]
        var at: Date
    }

    nonisolated static func file(in folder: URL) -> URL { folder.appendingPathComponent("listeners.json") }

    nonisolated static func read(from folder: URL) -> [String: Heard] {
        guard let data = try? Data(contentsOf: file(in: folder)),
              let all = try? JSONDecoder().decode([String: Heard].self, from: data) else { return [:] }
        return all
    }

    nonisolated static func write(_ all: [String: Heard], to folder: URL) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file(in: folder), options: .atomic)
    }

    /// The events heard for `version`, nil when what is kept is for another.
    nonisolated static func events(_ all: [String: Heard], id: String, version: String) -> [String]? {
        guard let kept = all[id], kept.version == version else { return nil }
        return kept.events
    }
}
