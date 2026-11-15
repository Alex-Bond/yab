import AppKit
import YabCoreClient

/// What a Chromium page can ask for beyond the camera, the microphone, where
/// you are and notifications, each named as Chromium's settings name it.
/// Yab's card asks, in place of Chromium's bubble, and the answer is kept for the
/// site like a notification's (docs/site-permissions.md). WebKit asks only
/// for pointer lock (WebKitPageEvents.requestPointerLock); its pages either
/// don't have the rest or don't ask.
enum SitePermission: String, CaseIterable {
    case clipboard, storage, topStorage = "top-storage", fonts, windows, idle, midi, pointer, keyboard, surface
    case protocolLinks = "protocol", files, quota

    /// What Site Controls calls it.
    var title: String {
        switch self {
        case .clipboard: return "Clipboard"
        case .storage, .topStorage: return "Cookies on other sites"
        case .fonts: return "Fonts"
        case .windows: return "Window management"
        case .idle: return "Device use"
        case .midi: return "MIDI devices"
        case .pointer: return "Pointer lock"
        case .keyboard: return "Keyboard lock"
        case .surface: return "Scrolling and zooming a shared tab"
        case .protocolLinks: return "Link types"
        case .files: return "Files"
        case .quota: return "Storage"
        }
    }

    /// What the card says it wants, after the site's name.
    var words: String {
        switch self {
        case .clipboard: return "see what you copied"
        case .storage, .topStorage: return "use its cookies and data on this site"
        case .fonts: return "use the fonts on this Mac"
        case .windows: return "manage windows on all your screens"
        case .idle: return "know when you’re using this Mac"
        case .midi: return "control your MIDI devices"
        case .pointer: return "lock and hide your pointer"
        case .keyboard: return "take over your keyboard"
        case .surface: return "scroll and zoom the tab you shared"
        case .protocolLinks: return "open a kind of link"
        case .files: return "see or change a file or folder you picked"
        case .quota: return "store more on this Mac"
        }
    }

    var symbol: String {
        switch self {
        case .clipboard: return "clipboard"
        case .storage, .topStorage: return "lock.open"
        case .fonts: return "textformat.abc"
        case .windows: return "macwindow"
        case .idle: return "clock"
        case .midi: return "music.note"
        case .pointer: return "cursor"
        case .keyboard: return "keyboard"
        case .surface: return "cursor.click"
        case .protocolLinks: return "link"
        case .files: return "folder"
        case .quota: return "archivebox"
        }
    }

    /// These last only as long as what asked: a handler lives in Chromium's
    /// own list, a file's grant with its handle, and Yab asks each time.
    var remembered: Bool { ![.protocolLinks, .files, .quota].contains(self) }

    nonisolated static func key(_ origin: String, _ kind: SitePermission) -> String { "permission.\(kind.rawValue).\(origin)" }

    /// Said for the site, by Browser.origin's spelling.
    @MainActor static func said(_ origin: String, _ kind: SitePermission) -> Bool? {
        Store.settings.object(forKey: key(origin, kind)) as? Bool
    }

    @MainActor static func remember(_ origin: String, _ kind: SitePermission, _ yes: Bool) {
        guard kind.remembered else { return }
        Store.settings.set(yes, forKey: key(origin, kind))
    }

    @MainActor static func forget(_ origin: String, _ kind: SitePermission) {
        Store.settings.removeObject(forKey: key(origin, kind))
    }

    /// Who the card says is asking: a site by its host, an extension's own
    /// page (a folder picked in its options page, #1683) by the extension's
    /// name rather than its 32-letter id. Nil when the origin names no one.
    @MainActor static func asker(_ origin: PageOrigin, extensions: [ChromiumExtensions.Item]) -> String? {
        guard !origin.host.isEmpty else { return nil }
        guard origin.scheme == Extensions.scheme,
              let name = extensions.first(where: { $0.id == origin.host })?.name,
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return origin.host }
        return name
    }
}

/// Chromium's own settings hold Yab's answers, so that what a page reads, its
/// Notification.permission and its navigator.permissions.query, is what Yab
/// remembers: under every space's profile, for a site allowed under WebKit
/// before it ever opened here, and at once when Yab's answer changes. Yab
/// stays the only one deciding: Chromium is told, and what it was told is
/// kept per profile so an answer taken back here is taken back there.
@MainActor
enum ChromiumPermissions {
    /// A setting Chromium holds, "<origin>|<kind>" to "allow" or "block".
    typealias Table = [String: String]

    /// Everything Yab remembers, as Chromium's settings name it.
    static func wanted(_ settings: [String: Any] = Store.settings.dictionaryRepresentation()) -> Table {
        var table: Table = [:]
        let put = { (origin: String, kinds: [String], yes: Bool) in
            let url = SiteNotices.webKitOrigin(origin)
            for kind in kinds { table["\(url)|\(kind)"] = yes ? "allow" : "block" }
        }
        for (key, value) in settings {
            guard let yes = value as? Bool else {
                if key == WindowGate.key, let sites = value as? [String] {
                    // A site, as WindowGate names it, without its "www.".
                    for site in sites {
                        put("https://\(site)", ["popups"], true)
                        put("https://www.\(site)", ["popups"], true)
                    }
                }
                if key == LocalNetwork.settingsKey, let rows = value as? [String] {
                    for row in rows {
                        let parts = row.split(separator: "|", maxSplits: 1).map(String.init)
                        if parts.count == 2 { put(parts[0], [parts[1] == "loopback" ? "loopback-network" : "local-network"], true) }
                    }
                }
                continue
            }
            if key.hasPrefix("notifications.") {
                let origin = String(key.dropFirst("notifications.".count))
                if SiteNotices.origin(webKit: origin) != nil { put(origin, ["notifications"], yes) }
            } else if key.hasPrefix("capture.") {
                let rest = String(key.dropFirst("capture.".count))
                let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let raw = Int(parts[1]), let type = PageCapture(rawValue: raw) else { continue }
                // Said before the scheme and the port counted: https's.
                let origin = parts[0].contains("://") ? parts[0] : Browser.origin(scheme: "https", host: parts[0], port: 443)
                put(origin, type == .camera ? ["camera"] : type == .microphone ? ["microphone"] : ["camera", "microphone"], yes)
            } else if key.hasPrefix("location.") {
                let rest = String(key.dropFirst("location.".count))
                put(rest.contains("://") ? rest : Browser.origin(scheme: "https", host: rest, port: 443), ["location"], yes)
            } else if key.hasPrefix("permission.") {
                for kind in SitePermission.allCases where kind.remembered && key.hasPrefix("permission.\(kind.rawValue).") {
                    put(String(key.dropFirst("permission.\(kind.rawValue).".count)), [kind.rawValue], yes)
                }
            } else if key.hasPrefix(SiteDownloads.manyPrefix) {
                // A site's automatic downloads, said for the site and kept by
                // Chromium per origin: told for each origin it was said on.
                // Chromium holds no answer of its own there (YabCore's
                // AnswerDownloads), so what it holds is what Site Controls shows.
                let site = String(key.dropFirst(SiteDownloads.manyPrefix.count))
                for origin in SiteDownloads.askedOn(site, in: settings) { put(origin, ["automatic-downloads"], yes) }
            }
        }
        return table
    }

    /// What one profile's pages are told: everything remembered, and each
    /// camera or microphone allowed on a visit still going on in a tab of
    /// that profile (Browser.visitGrants), as Chromium's "Allow this time" is
    /// held in its settings until the tab closes or leaves the site. Chromium
    /// reads only its settings to list a site's speakers and to let it pick
    /// one: a yes held by Yab alone left a call without them.
    static func goal(_ profile: String, remembered: Table? = nil,
                     visits: [(site: String, types: Set<PageCapture>)]? = nil) -> Table {
        var table = remembered ?? wanted()
        for visit in visits ?? Browser.visitGrants(profile: profile) {
            let url = SiteNotices.webKitOrigin(visit.site)
            var kinds: [String] = []
            if visit.types.contains(.camera) || visit.types.contains(.cameraAndMicrophone) { kinds.append("camera") }
            if visit.types.contains(.microphone) || visit.types.contains(.cameraAndMicrophone) { kinds.append("microphone") }
            for kind in kinds where table["\(url)|\(kind)"] == nil { table["\(url)|\(kind)"] = "allow" }
        }
        return table
    }

    /// What to write: every answer that differs, and "default" for what
    /// Chromium was told once and Yab no longer says.
    static func changes(from applied: Table, to wanted: Table) -> [(origin: String, kind: String, value: String)] {
        var out: [(origin: String, kind: String, value: String)] = []
        for (entry, value) in wanted where applied[entry] != value { out.append(split(entry, value)) }
        for entry in applied.keys where wanted[entry] == nil { out.append(split(entry, "default")) }
        return out.sorted { ($0.origin, $0.kind) < ($1.origin, $1.kind) }
    }

    private static func split(_ entry: String, _ value: String) -> (origin: String, kind: String, value: String) {
        let parts = entry.split(separator: "|", maxSplits: 1).map(String.init)
        return (parts.first ?? "", parts.count > 1 ? parts[1] : "", value)
    }

    private static func appliedKey(_ profile: String) -> String { "chromium.permissions.\(profile)" }
    /// The profiles open in this helper, by the helper that has them.
    private static var open: (client: ObjectIdentifier, profiles: Set<String>)?
    private static var watching = false
    private static var pending: DispatchWorkItem?
    /// What every open profile was last brought to. Any write to the
    /// settings says only that something changed: one read of them all
    /// finds whether these answers did, rather than one per open profile.
    private static var said: [String: Table]?

    /// A profile about to show pages: Chromium hears Yab's answers first.
    static func opened(_ profile: String, core: YabCoreClient) async {
        watch()
        let id = ObjectIdentifier(core)
        if open?.client != id { open = (id, []); said = nil }
        let first = open?.profiles.insert(profile).inserted == true
        await apply(profile, core: core, goal: goal(profile), again: first)
    }

    /// True when `goal` differs from what was last said to every profile.
    static func due(_ goal: Table, after said: Table?) -> Bool { goal != said }

    /// `again`: the profile's first page under this helper, when everything
    /// is said again, in case Chromium lost it, not only what changed.
    /// True when Chromium has `goal`.
    @discardableResult
    private static func apply(_ profile: String, core: YabCoreClient, goal: Table, again: Bool = false) async -> Bool {
        var applied = Store.settings.dictionary(forKey: appliedKey(profile)) as? Table ?? [:]
        if again { applied = applied.filter { goal[$0.key] == nil } }
        let list = changes(from: applied, to: goal)
        guard !list.isEmpty else { return true }
        let entries = list.map { row in
            JSONValue.object(["origin": .string(row.origin), "kind": .string(row.kind), "value": .string(row.value)])
        }
        guard (try? await core.request("permission.set", params: ["profile": .string(profile), "entries": .array(entries)])) != nil else { return false }
        Store.settings.set(goal, forKey: appliedKey(profile))
        stopCapture(taken: list.filter { ["camera", "microphone"].contains($0.kind) && $0.value != "allow" }.map(\.origin))
        return true
    }

    /// A stream in use doesn't hear a setting change: taken back, it stops.
    private static func stopCapture(taken origins: [String]) {
        guard !origins.isEmpty else { return }
        for browser in BrowserWindows.shared.browsers {
            for tab in browser.everyTab {
                guard let page = tab.builtPage as? ChromiumPage, let origin = Browser.origin(of: tab.address),
                      origins.contains(SiteNotices.webKitOrigin(origin)) else { continue }
                page.stopNativeCapture(kind: "userMedia")
            }
        }
    }

    /// One profile brought to its goal now, not after the pause `changed`
    /// waits: a call told yes lists its devices the moment its stream starts,
    /// as in Chromium, where the grant is kept before the page hears it.
    static func settle(_ profile: String) async {
        guard let core = ChromiumProcess.shared.connectedClient, let open, open.client == ObjectIdentifier(core),
              open.profiles.contains(profile) else { return }
        await apply(profile, core: core, goal: goal(profile))
    }

    /// Yab's answers changed, from a card, Site Controls, Settings or sync.
    private static func watch() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: Store.settings, queue: nil) { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { changed() } }
        }
    }

    static func changed() {
        pending?.cancel()
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                guard let core = ChromiumProcess.shared.connectedClient, let open, open.client == ObjectIdentifier(core) else { return }
                let remembered = wanted()
                let goals = Dictionary(uniqueKeysWithValues: open.profiles.map { ($0, goal($0, remembered: remembered)) })
                guard goals != said else { return }
                Task { @MainActor in
                    var whole = true
                    for (profile, goal) in goals {
                        if !(await apply(profile, core: core, goal: goal)) { whole = false }
                    }
                    if whole, Self.open?.client == open.client { said = goals }
                }
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }

    /// Whether Yab keeps the answer just given, which is what tells Chromium
    /// to keep or forget its own copy of it.
    static func keeps(_ question: [String: JSONValue], origin: PageOrigin, tab: Tab? = nil) -> Bool {
        let site = Browser.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        switch question["kind"]?.string ?? "" {
        case "notifications": return SiteNotices.said(site) != nil
        case "location": return Browser.locationSaid(site, host: origin.host) != nil
        case "capture":
            let camera = question["camera"] == .bool(true), microphone = question["microphone"] == .bool(true)
            let type: PageCapture = camera && microphone ? .cameraAndMicrophone : camera ? .camera : .microphone
            return Store.settings.object(forKey: Browser.captureKey(site, type)) != nil
                || Browser.covered(site, host: origin.host, type) == true
                // Held for the visit (goal), and taken back when it ends.
                || tab.flatMap { Browser.allowedThisVisit($0, site, type) } == true
        case "permission":
            guard case .array(let names)? = question["permissions"] else { return false }
            return names.allSatisfy { name in
                guard let name = name.string else { return false }
                // Refused only until Yab quits, so Chromium mustn't keep it.
                if name == "local-network" { return LocalNetwork.said(site, .local) == true }
                if name == "loopback-network" { return LocalNetwork.said(site, .loopback) == true }
                guard let kind = SitePermission(rawValue: name) else { return false }
                return !kind.remembered || SitePermission.said(site, kind) != nil
            }
        default: return false
        }
    }
}

extension Browser {
    /// A question Chromium asks, and WebKit for pointer lock. Kept for the
    /// site whichever way it is answered, with no box, as a notification's is.
    func page(_ page: any PageHandle, permission kind: SitePermission, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) {
        let webView = page as? ChromiumPage
        let lifetime = webView?.questionRequests.presentingPermission
        guard lifetime?.isActive != false, let tab = self.tab(owning: page) else { return reply(false) }
        let site = Self.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        // A private window neither uses what was said nor leaves anything said.
        if !tab.shy, let said = SitePermission.said(site, kind) { return reply(said) }
        let named = origin.scheme == Extensions.scheme ? webView?.extensions.items ?? [] : []
        let host = SitePermission.asker(origin, extensions: named) ?? tab.address?.host() ?? "This page"
        let question = PageAsk(kind: .site(kind), host: host)
        lifetime?.whenCancelled { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.withdrawAsk(question.id, on: tab)
        }
        ask(question, on: tab) { answer, question in
            guard lifetime?.isActive != false else { return reply(false) }
            var yes = false
            if case .yes = answer { yes = true }
            if question.ticked, !tab.shy { SitePermission.remember(site, kind, yes) }
            reply(yes)
        }
    }

    /// Chrome's own two local network questions on a Chromium page: its check
    /// is the real one, so the card is all that's left to WebKit's rule.
    func page(_ page: any PageHandle, localNetwork kind: LocalNetwork.Kind, origin: PageOrigin,
              reply: @escaping @MainActor (Bool) -> Void) {
        let lifetime = (page as? ChromiumPage)?.questionRequests.presentingPermission
        guard lifetime?.isActive != false, let tab = self.tab(owning: page) else { return reply(false) }
        let site = Self.origin(scheme: origin.scheme, host: origin.host, port: origin.port)
        if let said = LocalNetwork.said(site, kind) { return reply(said) }
        let question = PageAsk(kind: .localNetwork(kind == .loopback), host: origin.host)
        lifetime?.whenCancelled { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.withdrawAsk(question.id, on: tab)
        }
        ask(question, on: tab) { answer, _ in
            guard lifetime?.isActive != false else { return reply(false) }
            var yes = false
            if case .yes = answer { yes = true }
            LocalNetwork.remember(site, kind, yes)
            reply(yes)
        }
    }
}
