import AppKit
import UserNotifications
import YabCoreClient

// A Chromium page's notifications, and its service workers'. Chromium's own
// macOS service runs as it does upstream, with Yab where macOS would be
// (YabCore/src/site_notice_center.mm): it hands over each one as it would
// post it, and hears back what the person did, so `notificationclick`,
// `onclose`, a tag's replacing and `getNotifications()` stay Chromium's. The
// banner is Yab's, as a WebKit page's is: its name, one stack a site, no
// banner over the site you're looking at, Turn Off from its Options.
//
// An extension's (chrome.notifications, or a Notification its pages or worker
// show) comes the same way, from chrome-extension://ID. Chrome shows it with
// no question: the extension holds `notifications`, granted at install, and
// Chromium has already checked that before it hands one over. It is said
// under the extension's name and icon, wears only its own buttons, and a
// click goes to the extension alone (onClicked, onButtonClicked, onClosed),
// as Chromium's does: no site's tab comes forward, none opens.
extension SiteNotices {
    /// What Chromium needs to know which notification the person answered.
    struct Chromium: Equatable {
        var key: String
        var id: String
        /// As Chromium wrote it, which is how it finds the worker again.
        var origin: String
        var profile: String
        var incognito: Bool
        var type: Int
        var directory: String
        var buttons: [String]
        var image: Data?
        /// What Chromium put under the title: an extension's contextMessage.
        /// A site's is its origin, which Yab says in its own way.
        var subtitle = ""

        /// Kept in the banner's userInfo, so a click after Yab restarted can
        /// still say which one.
        var fields: [String: Any] {
            ["key": key, "id": id, "origin": origin, "profile": profile, "incognito": incognito, "type": type, "directory": directory]
        }

        init?(fields: [String: Any]) {
            guard let id = fields["id"] as? String else { return nil }
            key = fields["key"] as? String ?? ""
            self.id = id
            origin = fields["origin"] as? String ?? ""
            profile = fields["profile"] as? String ?? ""
            incognito = fields["incognito"] as? Bool ?? false
            type = fields["type"] as? Int ?? 0
            directory = fields["directory"] as? String ?? ""
            buttons = []
        }

        init?(event: [String: JSONValue]) {
            guard let id = event["id"]?.string, !id.isEmpty else { return nil }
            key = event["key"]?.string ?? ""
            self.id = id
            origin = event["origin"]?.string ?? ""
            profile = event["profile"]?.string ?? ""
            incognito = event["incognito"] == .bool(true)
            type = Int(event["type"]?.number ?? 0)
            directory = event["directory"]?.string ?? ""
            if case .array(let list)? = event["buttons"] { buttons = list.compactMap(\.string) } else { buttons = [] }
            image = event["image"]?.string.flatMap { Data(base64Encoded: $0) }
            subtitle = event["subtitle"]?.string ?? ""
        }

        /// NotificationHandler::Type: WEB_PERSISTENT, a service worker's;
        /// EXTENSION, chrome.notifications.
        static let workerType = 0, extensionType = 2

        /// A service worker's, rather than a page's. By its type: an
        /// extension's id is the extension's own (a to p) and may start "p".
        var worker: Bool { type == Self.workerType }

        /// The extension that showed it, through chrome.notifications or
        /// the Notification of one of its pages or its worker.
        var extensionID: String? {
            guard let url = URL(string: origin), url.scheme == "chrome-extension", let host = url.host(),
                  ChromiumExtensions.validID(host) else { return nil }
            return host
        }

        /// p[b]#<origin>#[1|0][<tag>|<number>], n#<origin>#<token>. Only a
        /// persistent one carries the site's own tag.
        var tag: String {
            guard worker, let origin = id.range(of: "#"),
                  let end = id.range(of: "#", range: origin.upperBound..<id.endIndex) else { return "" }
            let rest = id[end.upperBound...]
            return rest.first == "1" ? String(rest.dropFirst()) : ""
        }
    }

    /// Numbered from here, far from WebKit's own ids. The same notification
    /// keeps its number, so what the page replaces replaces it here.
    private static var numbers: [String: UInt64] = [:]
    private static var nextNumber: UInt64 = 1 << 62

    private static func number(_ id: String) -> UInt64 {
        if let known = numbers[id] { return known }
        nextNumber += 1
        numbers[id] = nextNumber
        return nextNumber
    }

    /// Events from the helper. True if it was one of these.
    static func receive(_ event: YabCoreEvent) -> Bool {
        switch event.name {
        case "notification.show":
            show(event.params)
        case "notification.close":
            guard let id = event.params["id"]?.string, let number = numbers[id], let note = standing.removeValue(forKey: number) else { return true }
            if AgentNotices.possible, !Store.testing {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [note.request])
            }
        case "notification.closeAll":
            let gone = standing.filter { $0.value.chromium != nil }
            for id in gone.keys { standing[id] = nil }
            if AgentNotices.possible, !Store.testing {
                UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: gone.values.map(\.request))
            }
        default:
            return false
        }
        return true
    }

    private static func show(_ fields: [String: JSONValue]) {
        guard let chromium = Chromium(event: fields), let written = fields["origin"]?.string,
              let origin = origin(webKit: written) else { return }
        // Never in a private window, as WebKit never does.
        guard !chromium.incognito else { return }
        if let id = chromium.extensionID { return showExtension(id, chromium, origin: origin, fields: fields) }
        // Yab decides. Chromium can only hold what Yab told it, and this is
        // the last place to say no if the two ever differ.
        guard said(origin) == true else {
            ChromiumPermissions.changed()
            return tellChromium(gone: [chromium])
        }
        let note = Note(id: number(chromium.id), worker: chromium.worker, origin: origin,
                        title: fields["title"]?.string ?? "", body: fields["body"]?.string ?? "",
                        tag: chromium.tag, icon: "", tab: tab(for: origin)?.tab.id, chromium: chromium)
        Task { await post(note) }
        if let page = URL(string: origin), page.host() != nil {
            let title = note.title, body = note.body
            Task { @MainActor in Promises.shared.heard(origin: page, title: title, body: body) }
        }
    }

    /// An extension's: allowed as Chromium allows it, by the `notifications`
    /// it was installed with (Chromium hands over none without it). Yab
    /// keeps no answer for it and asks nothing.
    private static func showExtension(_ id: String, _ chromium: Chromium, origin: String, fields: [String: JSONValue]) {
        let shown = Note(id: number(chromium.id), worker: chromium.worker, origin: origin,
                         title: fields["title"]?.string ?? "", body: fields["body"]?.string ?? "",
                         tag: chromium.tag, icon: "", tab: nil, chromium: chromium)
        Task {
            var note = shown
            let row = await extensionRow(id, profile: chromium.profile)
            note.from = row?.name ?? ""
            note.fromIcon = row?.iconData
            await post(note)
        }
    }

    /// The extension as Yab lists it; read from Chrome once more when this
    /// launch hasn't listed its profile yet. Chromium's profile id is the
    /// folder's name, "space-" and Yab's profile.
    static func extensionRow(_ id: String, profile: String) async -> ChromiumExtensions.Item? {
        let lists = ChromiumExtensions.profiles.values.filter { !$0.privateMode }
        for list in lists { if let row = list.items.first(where: { $0.id == id }) { return row } }
        let name = profile.hasPrefix("space-") ? String(profile.dropFirst("space-".count)) : profile
        for list in lists where list.profile == name {
            if let row = try? await list.list().first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    // MARK: - buttons

    nonisolated static func buttonAction(_ index: Int) -> String { "site.button.\(index)" }

    /// A page's own buttons (`actions`, two at most) beside Turn Off: each
    /// set of words a category of its own, added to what the app has. An
    /// extension's wears its own buttons alone, as Chromium's does.
    static func addButtons(_ note: Note, to content: UNMutableNotificationContent) async {
        guard let buttons = note.chromium?.buttons, !buttons.isEmpty, AgentNotices.possible, !Store.testing else { return }
        let fromExtension = note.chromium?.extensionID != nil
        let id = (fromExtension ? extensionCategory : category) + "." + buttons.joined(separator: "|")
        content.categoryIdentifier = id
        let center = UNUserNotificationCenter.current()
        var all = await center.notificationCategories()
        guard !all.contains(where: { $0.identifier == id }) else { return }
        let own = buttons.prefix(2).enumerated().map { index, title in
            UNNotificationAction(identifier: buttonAction(index), title: title, options: [.foreground])
        }
        let base = fromExtension ? [] : categories.first(where: { $0.identifier == category })?.actions ?? []
        all.insert(UNNotificationCategory(identifier: id, actions: own + base, intentIdentifiers: [], options: [.customDismissAction]))
        center.setNotificationCategories(all)
    }

    // MARK: - the person's answer

    /// Handled here if it is about Chromium's notification. Turn Off and
    /// Site Controls are Yab's own, whichever engine showed it.
    static func answer(_ action: String, _ chromium: Chromium, origin: String, id: UInt64?, tab: UUID?) -> Bool {
        switch action {
        case turnOff, controls:
            return false
        case UNNotificationDismissActionIdentifier:
            if let id { standing[id] = nil }
            tell(chromium, action: "close", index: 0)
        case _ where chromium.extensionID != nil:
            // Yab comes forward; what opens is
            // the extension's to say.
            let index = (0...1).first { action == buttonAction($0) }
            bringForward()
            if let id {
                clicked.append(id)
                standing[id] = nil
            }
            tell(chromium, action: index == nil ? "click" : "button", index: index ?? 0)
        default:
            let index = (0...1).first { action == buttonAction($0) }
            let found = front(origin, tab: tab)
            if let id {
                clicked.append(id)
                standing[id] = nil
            }
            let reopen = found == nil
            tell(chromium, action: index == nil ? "click" : "button", index: index ?? 0) { answered in
                // The helper has gone since, with what could answer: the
                // site, as a closed tab's click brings it.
                guard reopen, !answered, let url = URL(string: webKitOrigin(origin)) else { return }
                let browser = BrowserWindows.shared.browser(for: NSApp.keyWindow) ?? BrowserWindows.shared.browsers.first
                _ = browser?.open(url, foreground: true)
            }
        }
        return true
    }

    private static func tell(_ chromium: Chromium, action: String, index: Int, done: (@MainActor (Bool) -> Void)? = nil) {
        Task { @MainActor in
            guard let core = try? await ChromiumProcess.shared.connection() else { done?(false); return }
            let reply = try? await core.request("notification.answer", params: params(chromium, action: action, index: index))
            done?(reply?["answered"] == .bool(true))
        }
    }

    private static func params(_ chromium: Chromium, action: String, index: Int) -> [String: JSONValue] {
        ["action": .string(action), "index": .number(Double(index)), "key": .string(chromium.key), "id": .string(chromium.id),
         "origin": .string(chromium.origin), "profile": .string(chromium.profile), "incognito": .bool(chromium.incognito),
         "type": .number(Double(chromium.type)), "directory": .string(chromium.directory)]
    }

    /// Taken down by Yab (turned off, forgotten, no longer allowed): Chromium
    /// hears it closed, as if the person had swept it away.
    static func tellChromium(gone: [Chromium]) {
        guard let core = ChromiumProcess.shared.connectedClient else { return }
        Task { @MainActor in
            for chromium in gone {
                _ = try? await core.request("notification.answer", params: params(chromium, action: "close", index: 0))
            }
        }
    }
}
