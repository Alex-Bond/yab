import Foundation

/// Links that reach Yab from other apps. As the default browser, http and
/// https links come as they are; until Apple grants that entitlement, and
/// for tests (`xcrun simctl openurl`), `yab-open://<the link, URL-encoded>`
/// carries one in.
enum Links {
    /// An opt-in journal for the external-link lifecycle probes.
    static func trace(_ event: @autoclosure () -> String) {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["YAB_LINK_JOURNAL"],
              let data = "\(Date().timeIntervalSince1970) pid=\(ProcessInfo.processInfo.processIdentifier) \(event())\n".data(using: .utf8) else { return }
        if let file = FileHandle(forWritingAtPath: path) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: data)
        } else { try? data.write(to: URL(fileURLWithPath: path)) }
        #endif
    }

    static let scheme = "yab-open"

    /// The page a link opened from another app asks for, or nil when it isn't one.
    static func page(for url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return url
        case scheme:
            // Everything after the scheme, decoded: yab-open://https%3A%2F%2F… or yab-open:https://…
            var rest = String(url.absoluteString.dropFirst(scheme.count + 1))
            if rest.hasPrefix("//") { rest = String(rest.dropFirst(2)) }
            return page(address: rest.removingPercentEncoding ?? rest)
        default:
            return nil
        }
    }

    /// The page an address from another app asks for (yab-open's, or one the
    /// share sheet queued): http or https as it is, else read as the field
    /// reads typed words (example.com/a is https://example.com/a).
    static func page(address: String) -> URL? {
        let decoded = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if let link = URL(string: decoded), ["http", "https"].contains(link.scheme?.lowercased() ?? "") { return link }
        return Words.address(decoded)
    }

    /// The link for a page, wrapped for yab-open (for tests that open one).
    static func wrapped(_ page: URL) -> URL? {
        let encoded = page.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? page.absoluteString
        return URL(string: "\(scheme)://\(encoded)")
    }
}

extension AppModel {
    /// A link from another app: a new tab at the top of today's in this
    /// space, in front. A yab:// route (YabRoute) is one of the ways into
    /// Yab from outside it (Entrances).
    func openLink(_ url: URL) {
        Links.trace("openLink url=\(url) before=\(browser.tab?.id ?? "nil")")
        defer { Links.trace("openLink after=\(browser.tab?.id ?? "nil") url=\(browser.tab?.address ?? "nil")") }
        if let route = YabRoute(url) { return Entrances.perform(.route(route)) }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { DefaultBrowser.linkArrived() }
        if openNow(url) { return }
        guard let page = Links.page(for: url) else { return }
        openFromOutside(page)
    }

    /// A page from outside Yab (another app, the share sheet, Shortcuts, a
    /// Now row): what stood over the page is put away and the page is a tab
    /// at the top of today's. A locked private space asks for Face ID first.
    func openFromOutside(_ url: URL) {
        let destination = browser.space.id
        if browser.space.isPrivate, !privateLock.mayReveal {
            privateLock.request { [weak self] in
                guard let self, let space = self.browser.space(destination), space.isPrivate, self.privateLock.mayReveal else { return }
                self.openFromOutside(url, in: space)
            }
            return
        }
        openFromOutside(url, in: browser.space)
    }

    private func openFromOutside(_ url: URL, in space: Space) {
        taskDesk.dismissForLink()
        // All Tabs covers the selected page too, outside Surfaces' sheets.
        TabStack.of(self).dismissGallery()
        surfaces.closeMenu()
        if surfaces.field != nil { surfaces.closeField() }
        if surfaces.chat != nil { surfaces.closeChat() }
        if surfaces.settings { surfaces.closeSettings() }
        if surfaces.join { surfaces.closeJoin() }
        let tab = PageFixtures.tab(for: url, id: PageFixtures.newID(), isPrivate: space.isPrivate, in: world, fixturesEnabled: fixturesEnabled)
        // A remembered synced row can be removed by catch-up after this tap.
        // Keep the incoming page under a fresh local identity until the line
        // and scene are live; otherwise that old row can take the link with it.
        let reuseExisting = space.isPrivate || sync.phase != .on || (privateLock.isActive && sync.line == .live)
        if let kept = keepLink(tab, in: space.id, reuseExisting: reuseExisting) { profile?.outsideTabIDs.insert(kept) }
    }

    /// A link kept as a tab at the top of today's in this space. One page,
    /// one row: already in today's, it moves to the top instead.
    @discardableResult
    func keepLink(_ page: Tab, in destinationID: Space.ID? = nil, reuseExisting: Bool = true) -> Tab.ID? {
        guard let destination = browser.space(destinationID ?? browser.spaceID),
              !page.isPrivate || destination.isPrivate,
              !(page.isPrivate || destination.isPrivate) || privateLock.mayReveal else { return nil }
        let address = fixturesEnabled ? BrowserStore.samePage(page.address) : page.navigationURL?.absoluteString
        if reuseExisting, let address, let same = destination.allTabs.first(where: {
            $0.isPrivate == destination.isPrivate && (fixturesEnabled ? BrowserStore.samePage($0.address) : $0.navigationURL?.absoluteString) == address
        }) {
            browser.reorder(same.id, to: 0)
            browser.select(same.id)
            return same.id
        }
        var tab = page
        tab.id = PageFixtures.newID()
        tab.place = .today
        tab.isPrivate = destination.isPrivate
        browser.open(tab, in: destination.id, deduplicate: false)
        return tab.id
    }
}
