import AppKit
import YabCoreClient

/// Chromium retains native permissions, API promises and tab identities. The
/// browser that actually owns the row performs placement and folder changes.
/// Concealed CEF producers always keep their original single WebContents.
@MainActor
enum ChromiumExtensionTabs {
    private struct Row {
        let tab: Tab
        let browser: Browser
        let id: Int
        let window: Int
        let popup: Bool
    }
    private struct Model {
        weak var browser: Browser?
        let groups: ExtensionGroups
    }
    private static var models: [String: Model] = [:]

    static func receive(_ event: YabCoreEvent, core: YabCoreClient) -> Bool {
        guard event.name == "extension.tabOperation" else { return false }
        guard let owner = event.tab, let operation = event.params["operation"]?.number,
              let method = event.params["method"]?.string, let profile = event.params["profile"]?.string,
              let extensionID = event.params["extensionId"]?.string,
              ChromiumExtensions.validID(extensionID), let text = event.params["arguments"]?.string else { return true }
        Task { @MainActor in
            var result: Any = NSNull(), failure = "", after: (() -> Void)?
            var events: [[String: Any]] = []
            do {
                let args = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] ?? []
                let rows = try await snapshot(core, owner: owner, profile: profile)
                let before = try groupSnapshot(rows, profile: profile)
                let answer = try await run(method, args, rows: rows, owner: owner, profile: profile, extensionID: extensionID, core: core)
                result = answer.0; after = answer.1
                try await ChromiumTabGroups.shared.syncNow()
                let fresh = try await snapshot(core, owner: owner, profile: profile)
                let afterGroups = try groupSnapshot(fresh, profile: profile)
                for (id, group) in before where afterGroups[id] == nil { events.append(["name": "removed", "group": group]) }
                for (id, group) in afterGroups {
                    if before[id] == nil { events.append(["name": "created", "group": group]) }
                    else if !NSDictionary(dictionary: before[id]!).isEqual(to: group) { events.append(["name": "updated", "group": group]) }
                }
                if method == "tabGroups.move", let group = result as? [String: Any] { events.append(["name": "moved", "group": group]) }
            } catch { failure = error.localizedDescription }
            do {
                let data = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                let reply = try await core.request("extension.tabs.reply", params: ["tab": .string(owner), "operation": .number(operation),
                    "result": .string(String(decoding: data, as: UTF8.self)), "error": .string(failure),
                    "events": .string(String(decoding: try JSONSerialization.data(withJSONObject: events), as: UTF8.self))])
                if reply["accepted"] == .bool(true) { after?() }
            } catch { DebugLog.note("chromium-tab-operation", ["api": method, "error": String(describing: error)]) }
        }
        return true
    }

    private static func snapshot(_ core: YabCoreClient, owner: String, profile: String) async throws -> [Row] {
        let value = try await core.request("extension.tabs.snapshot", params: ["tab": .string(owner)])
        guard case .array(let list) = value else { throw refused("Invalid native tab snapshot") }
        let browsers = BrowserWindows.shared.browsers
        var known: [String: (Tab, Browser)] = [:]
        for browser in browsers {
            for tab in browser.tabs + browser.parkedTabs + browser.outside where tab.chromiumProfile == profile {
                if let page = tab.builtPage as? ChromiumPage, let remote = page.remoteID { known[remote] = (tab, browser) }
            }
        }
        return list.compactMap { item in
            guard let remote = item["remote"].string, let (tab, browser) = known[remote],
                  let id = item["id"].number, let window = item["windowId"].number else { return nil }
            return Row(tab: tab, browser: browser, id: Int(id), window: Int(window), popup: item["windowType"].string == "popup")
        }
    }

    private static func groupSnapshot(_ rows: [Row], profile: String) throws -> [Int: [String: Any]] {
        var result: [Int: [String: Any]] = [:], seen = Set<Int>()
        for row in rows where !row.popup && seen.insert(row.window).inserted {
            let groups = try model(row.browser, profile: profile).runLogical("tabGroups.query", [[:]]) as? [[String: Any]] ?? []
            for var group in groups {
                guard let id = group["id"] as? Int else { continue }
                group["windowId"] = row.window; result[id] = group
            }
        }
        return result
    }

    private static func refused(_ text: String) -> NSError {
        NSError(domain: "ChromiumExtensionTabs", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    private static func ids(_ value: Any?) -> [Int] {
        if let n = value as? NSNumber { return [n.intValue] }
        return (value as? [NSNumber] ?? []).map(\.intValue)
    }
    private static func model(_ browser: Browser, profile: String) -> ExtensionGroups {
        let key = "\(ObjectIdentifier(browser))/\(profile)"
        models = models.filter { $0.value.browser != nil }
        if let found = models[key], found.browser === browser { return found.groups }
        let made = ExtensionGroups(browser: browser, profile: profile)
        models[key] = Model(browser: browser, groups: made); return made
    }
    private static func run(_ method: String, _ args: [Any], rows: [Row], owner: String, profile: String,
                            extensionID: String, core: YabCoreClient) async throws -> (Any, (() -> Void)?) {
        let first = args.first
        func row(_ id: Int) throws -> Row {
            guard let row = rows.first(where: { $0.id == id }), !row.tab.gone else { throw refused("No tab with id: \(id).") }
            return row
        }
        func window(_ id: Int?) throws -> Row {
            if let id, id != -2 {
                guard let row = rows.first(where: { $0.window == id }) else { throw refused("No window with id: \(id).") }
                return row
            }
            guard let row = rows.first(where: { ($0.tab.builtPage as? ChromiumPage)?.remoteID == owner }) ?? rows.first else {
                throw refused("No current window")
            }
            return row
        }
        func move(_ chosen: Row, to destination: Row, index: Int) throws {
            guard !chosen.popup, !destination.popup else { throw refused("Tabs can only be moved to and from normal windows.") }
            let focused = NSApp.keyWindow
            defer {
                if let focused, focused.isVisible, NSApp.keyWindow !== focused { focused.makeKeyAndOrderFront(nil) }
            }
            if chosen.browser !== destination.browser {
                guard BrowserWindows.shared.move(chosen.tab, from: chosen.browser, to: destination.browser, announce: false, selecting: false) else {
                    throw refused("The tab cannot move between these windows")
                }
            }
            let visible = destination.browser.tabs.filter { $0.chromiumProfile == profile }
            let at = index < 0 ? max(0, visible.count - 1) : min(index, max(0, visible.count - 1))
            if let target = visible.indices.contains(at) ? destination.browser.tabs.firstIndex(where: { $0 === visible[at] }) : nil {
                destination.browser.move(chosen.tab, to: target)
            }
        }
        switch method {
        case "tabs.create":
            let spec = first as? [String: Any] ?? [:]
            let destination = try window((spec["windowId"] as? NSNumber)?.intValue)
            guard !destination.popup else { throw refused("Tabs can only be created in normal windows") }
            let text = spec["url"] as? String ?? "about:blank"
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") || text == "about:blank" ||
                    (url.scheme == "chrome-extension" && url.host == extensionID) else { throw refused("The extension cannot open this URL") }
            let opener = try (spec["openerTabId"] as? NSNumber).map { try row($0.intValue) }
            guard opener == nil || opener?.browser === destination.browser else { throw refused("The opener must be in the same window") }
            let tab = destination.browser.open(url, foreground: (spec["active"] ?? spec["selected"]) as? Bool ?? true, atEnd: true, rowNow: true)
            var accepted = false
            defer { if !accepted { destination.browser.close(tab) } }
            if spec["pinned"] as? Bool == true { destination.browser.pin(tab) }
            if let index = spec["index"] as? NSNumber { destination.browser.move(tab, to: min(max(0, index.intValue), destination.browser.tabs.count - 1)) }
            if let opener { tab.opener = opener.tab.id }
            guard let page = tab.page as? ChromiumPage, page.profile == profile else { throw refused("The requested site uses another engine or profile") }
            _ = try await page.endpoint()
            try await ChromiumTabGroups.shared.syncNow()
            let fresh = try await snapshot(core, owner: owner, profile: profile)
            guard let created = fresh.first(where: { $0.tab === tab }) else { throw refused("The new tab was not listed natively") }
            accepted = true
            return (created.id, nil)
        case "tabs.move":
            let chosen = try ids(first).map(row), spec = args.dropFirst().first as? [String: Any] ?? [:]
            guard !chosen.isEmpty else { throw refused("No tabs given") }
            let destination = try window((spec["windowId"] as? NSNumber)?.intValue ?? chosen.first?.window)
            let index = (spec["index"] as? NSNumber)?.intValue ?? -1
            for (offset, tab) in chosen.enumerated() { try move(tab, to: destination, index: index < 0 ? -1 : index + offset) }
            // CEF reconstructs the real tab objects and scrubs URL/title there.
            return (chosen.count == 1 ? chosen[0].id as Any : chosen.map(\.id), nil)
        case "tabs.group":
            let spec = first as? [String: Any] ?? [:]
            let chosen = try ids(spec["tabIds"]).map(row)
            guard !chosen.isEmpty else { throw refused("No tabs given") }
            let group = (spec["groupId"] as? NSNumber)?.intValue
            if group != nil && spec["createProperties"] != nil { throw refused("Specify either groupId or createProperties") }
            let create = spec["createProperties"] as? [String: Any] ?? [:]
            let destination: Row
            if let group {
                guard let existing = rows.first(where: { $0.tab.nest.map { ExtensionGroups.id(of: $0.id) } == group }) else { throw refused("No group with id: \(group).") }
                destination = existing
            } else { destination = try window((create["windowId"] as? NSNumber)?.intValue ?? chosen.first?.window) }
            guard !destination.popup, chosen.allSatisfy({ !$0.popup }) else { throw refused("Tabs can only be grouped in normal windows.") }
            for tab in chosen where tab.browser !== destination.browser { try move(tab, to: destination, index: -1) }
            let row = destination.browser.tabs.filter { $0.chromiumProfile == profile && !$0.shy }
            let indices = chosen.compactMap { chosen in row.firstIndex(where: { $0 === chosen.tab }) }
            guard indices.count == chosen.count else { throw refused("The group contains an unavailable tab") }
            var options: [String: Any] = ["indices": indices]
            if let group { options["groupId"] = group }
            return (try model(destination.browser, profile: profile).runLogical("tabGroups.group", [options]) ?? NSNull(), nil)
        case "tabs.ungroup":
            let chosen = try ids(first).map(row)
            for item in chosen { item.browser.unfile(item.tab) }
            return (NSNull(), nil)
        case "tabGroups.get", "tabGroups.update", "tabGroups.move":
            let group = (first as? NSNumber)?.intValue ?? -1
            guard let existing = rows.first(where: { $0.tab.nest.map { ExtensionGroups.id(of: $0.id) } == group }) else { throw refused("No group with id: \(group).") }
            var groupBrowser = existing.browser, groupWindow = existing.window
            if method == "tabGroups.move", let spec = args.dropFirst().first as? [String: Any], let target = spec["windowId"] as? NSNumber, target.intValue != existing.window {
                let destination = try window(target.intValue)
                guard let nest = existing.tab.nest else { throw refused("The group disappeared") }
                let members = rows.filter { $0.tab.nest === nest }
                for member in members { try move(member, to: destination, index: -1) }
                destination.browser.gather(members.map(\.tab), into: nest)
                groupBrowser = destination.browser; groupWindow = destination.window
            }
            var result = try model(groupBrowser, profile: profile).runLogical(method, args) as? [String: Any] ?? [:]
            result["windowId"] = groupWindow
            return (result, nil)
        case "tabGroups.query":
            let spec = first as? [String: Any] ?? [:]
            if spec["shared"] as? Bool == true { return ([Any](), nil) }
            let requested = (spec["windowId"] as? NSNumber)?.intValue
            let wanted: Int? = requested == -2 ? try window(nil).window : requested
            var seen = Set<Int>(), result: [[String: Any]] = []
            for row in rows where !row.popup && seen.insert(row.window).inserted {
                if let wanted, wanted != row.window { continue }
                let list = try model(row.browser, profile: profile).runLogical(method, args) as? [[String: Any]] ?? []
                result += list.map { var group = $0; group["windowId"] = row.window; return group }
            }
            return (result, nil)
        case "windows.create":
            let spec = first as? [String: Any] ?? [:], parent = try window(nil)
            guard !parent.browser.privateBrowsing, spec["incognito"] as? Bool != true else { throw refused("Creating a private window requires its own profile") }
            var urls = (spec["url"] as? [String]) ?? (spec["url"] as? String).map { [$0] } ?? ["about:blank"]
            if urls.isEmpty { urls = ["about:blank"] }
            let allowed = try urls.map { text -> URL in
                guard let url = URL(string: text), ["http", "https"].contains(url.scheme ?? "") || text == "about:blank" ||
                        (url.scheme == "chrome-extension" && url.host == extensionID) else { throw refused("The extension cannot open this URL") }
                return url
            }
            let selected = try (spec["tabId"] as? NSNumber).map { try row($0.intValue) }
            guard selected?.popup != true else { throw refused("Tabs can only be moved from normal windows") }
            let browser = BrowserWindows.shared.newWindow(from: parent.browser)
            let initial = browser.tabs
            var created: [Tab] = []
            if let selected {
                guard BrowserWindows.shared.move(selected.tab, from: selected.browser, to: browser, announce: false) else { throw refused("The tab cannot move to the new window") }
                created = [selected.tab]
            }
            for url in (created.isEmpty || spec["url"] != nil ? allowed : []) {
                let tab = browser.open(url, foreground: created.isEmpty, atEnd: true, rowNow: true)
                guard let page = tab.page as? ChromiumPage, page.profile == profile else { throw refused("The new window has a different profile") }
                _ = try await page.endpoint(); created.append(tab)
            }
            for tab in initial where !created.contains(where: { $0 === tab }) && (tab.address == nil || tab.address?.absoluteString == "about:blank") { browser.close(tab) }
            if spec["focused"] as? Bool == false { BrowserWindows.shared.window(for: parent.browser)?.makeKeyAndOrderFront(nil) }
            try await ChromiumTabGroups.shared.syncNow()
            let fresh = try await snapshot(core, owner: owner, profile: profile)
            guard let native = fresh.first(where: { row in row.browser === browser && created.contains(where: { $0 === row.tab }) }) else { throw refused("The new window was not listed natively") }
            return (native.window, nil)
        case "windows.remove":
            let target = try window((first as? NSNumber)?.intValue)
            if let popup = ChromiumExtensionWindow.showing(target.tab) { return (NSNull(), { popup.close() }) }
            guard let window = BrowserWindows.shared.window(for: target.browser) else { throw refused("No native window") }
            return (NSNull(), { window.performClose(nil) })
        default: throw refused("Unsupported native tab operation: \(method)")
        }
    }
}
