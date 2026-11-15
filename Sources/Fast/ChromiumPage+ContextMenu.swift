import AppKit
import YabDesign
import YabCoreClient

private extension JSONValue {
    var menuList: [JSONValue] { if case .array(let rows) = self { return rows }; return [] }
}

/// What Chromium said about a right-click, from its browser-process params
/// (CefContextMenuParams), never from a page-authored message.
struct ChromiumMenuContext {
    struct ExtensionRow: Equatable {
        let command: Int
        let label: String
        let enabled: Bool
        let checked: Bool
        let rows: [ExtensionRow]
    }

    let request: String
    /// Top-left page point of the press, in the page's points.
    let point: CGPoint
    let link: URL?
    let copyLink: String
    let source: URL?
    let media: Int
    let hasImage: Bool
    let selection: String
    let editable: Bool
    let editFlags: Int
    let misspelled: String
    let suggestions: [String]
    /// Chrome's own edit commands this menu offers (chrome_command_ids.h).
    let chrome: Set<Int>
    let extensions: [ExtensionRow]
    /// The press was in Chrome's DevTools: only their own rows.
    let devToolsFrontend: Bool

    static let copy = 50150, cut = 50151, paste = 50152, selectAll = 50156
    static let mediaImage = 1, mediaVideo = 2, mediaAudio = 3

    init?(_ p: [String: JSONValue]) {
        guard let request = p["request"]?.string, !request.isEmpty else { return nil }
        self.request = request
        point = CGPoint(x: p["x"]?.number ?? 0, y: p["y"]?.number ?? 0)
        let web = { (value: String?) -> URL? in
            guard let value, !value.isEmpty, let url = URL(string: value),
                  !["javascript", "chrome", "chrome-extension", "devtools"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }
        link = web(p["link"]?.string)
        copyLink = p["unfilteredLink"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? link?.absoluteString ?? ""
        source = web(p["source"]?.string)
        media = Int(p["media"]?.number ?? 0)
        hasImage = p["hasImage"] == .bool(true)
        selection = p["selection"]?.string ?? ""
        editable = p["editable"] == .bool(true)
        editFlags = Int(p["editFlags"]?.number ?? 0)
        misspelled = p["misspelled"]?.string ?? ""
        suggestions = (p["suggestions"]?.menuList ?? []).compactMap(\.string)
        chrome = Set((p["chrome"]?.menuList ?? []).compactMap { $0.number.map(Int.init) })
        func rows(_ value: JSONValue?, depth: Int) -> [ExtensionRow] {
            guard depth < 4 else { return [] }
            return (value?.menuList ?? []).compactMap { row in
                guard let command = row["command"].number, let label = row["label"].string else { return nil }
                return ExtensionRow(command: Int(command), label: label, enabled: row["enabled"] == .bool(true),
                                    checked: row["checked"] == .bool(true), rows: rows(row["rows"], depth: depth + 1))
            }
        }
        extensions = rows(p["extensions"], depth: 0)
        devToolsFrontend = p["devToolsFrontend"] == .bool(true)
    }
}

/// A row of Yab's page menu on a Chromium tab: WebKit's row identifiers, so
/// PageView.dress and every test that reads them see the same menu.
struct ChromiumMenuRow: Equatable {
    enum Action: Equatable {
        case chrome(Int)
        case openTab(URL), openHere(URL), download(URL), copy(String)
        case image(ImageAct, URL)
        case search(String), goTo(URL), lookUp(String), replace(String)
        case back, forward, reload
        case inspect
    }
    let title: String
    let id: String?
    let action: Action?
    var enabled = true
    var checked = false
    var rows: [ChromiumMenuRow?] = []

    /// The rows, nil for a separator, in WebKit's order for the same press.
    @MainActor static func rows(for c: ChromiumMenuContext, searchName: String, canGoBack: Bool, canGoForward: Bool,
                     askable: Bool) -> [ChromiumMenuRow?] {
        var out: [ChromiumMenuRow?] = []
        let section = { (rows: [ChromiumMenuRow]) in
            guard !rows.isEmpty else { return }
            if !out.isEmpty { out.append(nil) }
            out += rows
        }
        if c.editable, !c.misspelled.isEmpty {
            section(c.suggestions.isEmpty
                ? [ChromiumMenuRow(title: "No Guesses Found", id: nil, action: nil, enabled: false)]
                : c.suggestions.prefix(5).map { ChromiumMenuRow(title: $0, id: nil, action: .replace($0)) })
        }
        if let link = c.link {
            var rows: [ChromiumMenuRow] = []
            let scheme = link.scheme?.lowercased() ?? ""
            if scheme != "mailto" && scheme != "tel" {
                rows.append(ChromiumMenuRow(title: "Open Link in New Tab", id: "WKMenuItemIdentifierOpenLinkInNewWindow", action: .openTab(link)))
                rows.append(ChromiumMenuRow(title: "Open Link", id: "WKMenuItemIdentifierOpenLink", action: .openHere(link)))
                if ["http", "https", "data", "blob"].contains(scheme) {
                    rows.append(ChromiumMenuRow(title: "Download Linked File", id: "WKMenuItemIdentifierDownloadLinkedFile", action: .download(link)))
                }
            }
            rows.append(ChromiumMenuRow(title: "Copy Link", id: "WKMenuItemIdentifierCopyLink", action: .copy(c.copyLink)))
            if let address = PageView.emailAddress(link) {
                rows.append(ChromiumMenuRow(title: "Copy Email Address", id: "YabCopyEmailAddress", action: .copy(address)))
            }
            if let words = Self.words(c.selection), let url = SelectedURLMenu.url(words, besides: link.absoluteString) {
                rows.append(ChromiumMenuRow(title: "Go to “\(Address.pretty(url))”", id: "YabGoToSelectedURL", action: .goTo(url)))
            }
            section(rows)
        }
        if c.media == ChromiumMenuContext.mediaImage, let image = c.source {
            var rows = [ChromiumMenuRow(title: "Open Image in New Tab", id: "WKMenuItemIdentifierOpenImageInNewWindow", action: .image(.open, image)),
                        ChromiumMenuRow(title: "Download Image", id: "WKMenuItemIdentifierDownloadImage", action: .image(.download, image))]
            if c.hasImage {
                rows.append(ChromiumMenuRow(title: "Copy Image", id: "WKMenuItemIdentifierCopyImage", action: .image(.copy, image)))
            }
            rows.append(ChromiumMenuRow(title: "Copy Image Address", id: "YabCopyImageAddress", action: .image(.address, image)))
            if askable, c.hasImage {
                rows.append(ChromiumMenuRow(title: "Ask About Image", id: "YabAskAboutImage", action: .image(.ask, image)))
            }
            section(rows)
        } else if c.media == ChromiumMenuContext.mediaVideo || c.media == ChromiumMenuContext.mediaAudio, let media = c.source {
            let kind = c.media == ChromiumMenuContext.mediaAudio ? "Audio" : "Video"
            var rows = [ChromiumMenuRow(title: "Open \(kind) in New Tab", id: "WKMenuItemIdentifierOpenMediaInNewWindow", action: .openTab(media))]
            if ["http", "https"].contains(media.scheme?.lowercased() ?? "") {
                rows.append(ChromiumMenuRow(title: "Download \(kind)", id: "YabDownloadMedia", action: .download(media)))
            }
            rows.append(ChromiumMenuRow(title: "Copy \(kind) Address", id: "WKMenuItemIdentifierCopyMediaLink", action: .copy(media.absoluteString)))
            section(rows)
        }
        if let words = Self.words(c.selection), c.link == nil {
            var rows = [ChromiumMenuRow(title: "Look Up “\(Self.short(words))”", id: "WKMenuItemIdentifierLookUp", action: .lookUp(words))]
            if let url = SelectedURLMenu.url(words) {
                rows.append(ChromiumMenuRow(title: "Go to “\(Address.pretty(url))”", id: "YabGoToSelectedURL", action: .goTo(url)))
            }
            rows.append(ChromiumMenuRow(title: "Search with \(searchName)", id: "WKMenuItemIdentifierSearchWeb", action: .search(words)))
            section(rows)
        }
        if c.editable {
            var rows: [ChromiumMenuRow] = []
            for (title, command, id) in [("Cut", ChromiumMenuContext.cut, nil), ("Copy", ChromiumMenuContext.copy, "WKMenuItemIdentifierCopy"),
                                         ("Paste", ChromiumMenuContext.paste, "WKMenuItemIdentifierPaste")] as [(String, Int, String?)] {
                rows.append(ChromiumMenuRow(title: title, id: id, action: .chrome(command), enabled: c.chrome.contains(command)))
            }
            section(rows)
        } else if Self.words(c.selection) != nil, c.link == nil, c.chrome.contains(ChromiumMenuContext.copy) {
            section([ChromiumMenuRow(title: "Copy", id: "WKMenuItemIdentifierCopy", action: .chrome(ChromiumMenuContext.copy))])
        }
        if c.link == nil, c.source == nil || c.media == 0, Self.words(c.selection) == nil, !c.editable {
            section([ChromiumMenuRow(title: "Back", id: "WKMenuItemIdentifierGoBack", action: .back, enabled: canGoBack),
                     ChromiumMenuRow(title: "Forward", id: "WKMenuItemIdentifierGoForward", action: .forward, enabled: canGoForward),
                     ChromiumMenuRow(title: "Reload", id: "WKMenuItemIdentifierReload", action: .reload)])
        }
        func extensionRows(_ rows: [ChromiumMenuContext.ExtensionRow]) -> [ChromiumMenuRow?] {
            rows.map { row in
                ChromiumMenuRow(title: row.label, id: nil, action: row.rows.isEmpty ? .chrome(row.command) : nil,
                                enabled: row.enabled, checked: row.checked, rows: extensionRows(row.rows))
            }
        }
        section(extensionRows(c.extensions).compactMap { $0 })
        if !c.devToolsFrontend {
            section([ChromiumMenuRow(title: "Inspect Element", id: "WKMenuItemIdentifierInspectElement", action: .inspect)])
        }
        return out
    }

    static func words(_ selection: String) -> String? {
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// Look Up's title holds the words as WebKit's does, cut short.
    static func short(_ words: String) -> String {
        let flat = words.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 30 ? String(flat.prefix(29)) + "\u{2026}" : flat
    }
}

/// One right-click's menu on screen. Chrome's continuation stays open until
/// the row chosen is known, or a moment after the menu closed with none:
/// a row can be performed just after tracking ends (bench "press").
@MainActor
final class ChromiumMenuSession: NSObject {
    let context: ChromiumMenuContext
    weak var page: ChromiumPage?
    let remote: String?
    private var answered = false

    init(context: ChromiumMenuContext, page: ChromiumPage) {
        self.context = context
        self.page = page
        remote = page.remoteID
    }

    func answer(_ command: Int?) {
        guard !answered, let page, page.remoteID == remote else { return }
        answered = true
        var params: [String: JSONValue] = ["request": .string(context.request)]
        if let command { params["command"] = .number(Double(command)) }
        Task { @MainActor in _ = try? await page.navigationRequest("menu.reply", params) }
    }

    /// Held here, not by the rows (a menu item's target is weak), until then.
    func closed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.answer(nil) }
    }

    @objc func pick(_ item: NSMenuItem) {
        guard let box = item.representedObject as? Box, let page else { answer(nil); return }
        if case .chrome(let command) = box.action { answer(command); return }
        answer(nil)
        page.performMenu(box.action, at: context.point)
    }

    final class Box: NSObject {
        let action: ChromiumMenuRow.Action
        init(_ action: ChromiumMenuRow.Action) { self.action = action }
    }
}

extension ChromiumPage {
    func receiveMenu(_ p: [String: JSONValue]) {
        guard let context = ChromiumMenuContext(p) else { return }
        let session = ChromiumMenuSession(context: context, page: self)
        guard window != nil, let tab = navigationTab else { session.answer(nil); return }
        let rows = ChromiumMenuRow.rows(for: context, searchName: tab.onSearchName?(tab) ?? Engine.name,
                                        canGoBack: canGoBack, canGoForward: canGoForward, askable: !tab.shy)
        guard !rows.isEmpty else { session.answer(nil); return }
        let menu = Self.pageMenu(rows, session: session)
        let translation = tab.onTranslationMenu?(tab) ?? []
        if !translation.isEmpty {
            menu.addItem(.separator())
            translation.forEach(menu.addItem)
        }
        PageView.dress(menu)
        for item in menu.items where item.identifier == nil && item.action == #selector(ChromiumMenuSession.pick(_:)) {
            if let box = item.representedObject as? ChromiumMenuSession.Box, case .chrome(let command) = box.action, command < 50000, !isDevToolsFrontend {
                item.image = MenuMark.image("puzzlepiece.extension")
                MenuMark.show(item)
            }
        }
        PageView.menuWatch?(menu)
        let at = NSPoint(x: context.point.x, y: bounds.height - context.point.y)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { session.answer(nil); return }
            // popUp tracks in its own loop and returns once the menu closed.
            menu.popUp(positioning: nil, at: at, in: self)
            session.closed()
            self.lastInput = ProcessInfo.processInfo.systemUptime
        }
    }

    private static func pageMenu(_ rows: [ChromiumMenuRow?], session: ChromiumMenuSession) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            guard let row else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: row.title, action: nil, keyEquivalent: "")
            if let id = row.id { item.identifier = NSUserInterfaceItemIdentifier(id) }
            item.isEnabled = row.enabled
            item.state = row.checked ? .on : .off
            if !row.rows.isEmpty {
                item.submenu = pageMenu(row.rows, session: session)
            } else if let action = row.action {
                item.target = session
                item.action = #selector(ChromiumMenuSession.pick(_:))
                item.representedObject = ChromiumMenuSession.Box(action)
            }
            if row.id == "YabAskAboutImage", let key = Keymap.shared.keys(.agentAsk), key.key.count == 1 {
                item.keyEquivalent = key.key
                item.keyEquivalentModifierMask = key.flags
            }
            menu.addItem(item)
        }
        return menu
    }

    func performMenu(_ action: ChromiumMenuRow.Action, at point: CGPoint) {
        guard let tab = navigationTab else { return }
        let browser = tab.delegate as? Browser
        switch action {
        case .chrome: break
        case .inspect:
            browser?.inspectChromium(tab, at: point)
        case .openTab(let url):
            // Shift asks to show it, as WebKit's Open Link in New Tab does.
            let foreground = NSEvent.modifierFlags.contains(.shift)
            guard let browser else { return }
            if !browser.routePageLink(url, from: tab, foreground: foreground) {
                browser.open(url, foreground: foreground, from: tab, linked: true)
            }
        case .openHere(let url): tab.go(to: url)
        case .download(let url): startDownload(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .image(let act, let url):
            let flags = NSEvent.modifierFlags
            tab.onImageAct?(tab, act, url, !flags.contains(.command) || flags.contains(.shift))
        case .search(let words): tab.onSearch?(tab, words)
        case .goTo(let url): tab.onSelectedURL?(tab, url, NSEvent.modifierFlags)
        case .lookUp(let words):
            let text = NSAttributedString(string: words, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
            showDefinition(for: text, at: NSPoint(x: point.x, y: bounds.height - point.y))
        case .replace(let word):
            Task { @MainActor in _ = try? await navigationRequest("page.replaceMisspelling", ["text": .string(word)]) }
        case .back: tab.back()
        case .forward: tab.forward()
        case .reload: tab.reload()
        }
    }

    /// Through Chromium's own download manager, so the file arrives in the
    /// downloads list with the page's cookies, as any other of this tab's.
    func startDownload(_ url: URL) {
        ChromiumDownload.ask(url, on: self)
        Task { @MainActor in _ = try? await navigationRequest("page.download", ["url": .string(url.absoluteString)]) }
    }

    /// The picture's pixels as PNG, decoded by Chromium from its own fetch.
    func imageData(_ url: URL) async -> Data? {
        guard let value = try? await navigationRequest("page.imageData", ["url": .string(url.absoluteString)]),
              let png = value["png"].string else { return nil }
        return Data(base64Encoded: png)
    }
}
