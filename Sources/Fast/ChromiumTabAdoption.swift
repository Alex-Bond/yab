import AppKit
import YabCoreClient

@MainActor enum ChromiumTabAdoption {
    /// No fallback to another profile or privacy mode. Native tabs have
    /// already loaded, so opening their URL again would destroy their identity.
    static func install(_ event: YabCoreEvent, opener: Tab?, owner: Tab? = nil) -> Tab? {
        guard hasNativeRequest(event.params),
              let id = event.tab, let profile = event.params["profile"]?.string,
              case .bool(let privateMode) = event.params["private"],
              let identity = UUID(uuidString: privateMode ? String(profile.dropFirst("private-".count)) : profile),
              profile == (privateMode ? "private-" : "") + identity.uuidString else { return nil }
        // A profile is a sign-in, not an insertion space. Both popup openers
        // and extension owners originate in exact native browser receipts.
        if event.params["opener"]?.string != nil, opener == nil { return nil }
        if event.params["extensionCreation"]?["ownerTab"].string != nil, owner == nil { return nil }
        guard let anchor = opener ?? owner, !anchor.gone,
              (!anchor.pageStore.isPersistent) == privateMode, anchor.chromiumProfile == profile,
              let browser = anchor.delegate as? Browser else { return nil }
        if let owner, owner.gone || owner.chromiumProfile != profile || (owner.delegate as? Browser) !== browser { return nil }
        let space = browser.spaceHolding(anchor) ?? browser.spaceID
        guard browser.spaceID == space || browser.parked[space] != nil else { return nil }
        if let source = event.params["source"]?.object {
            guard let opener, let page = opener.builtPage,
                  let url = event.params["url"]?.string.flatMap(URL.init(string:)),
                  let origin = source["url"]?.string.flatMap(URL.init(string:)) else { return nil }
            let action = PageAction(request: URLRequest(url: url), kind: .other, targetIsMainFrame: nil,
                source: .init(isMainFrame: source["main"] == .bool(true), scheme: origin.scheme ?? "",
                              host: origin.host ?? "", port: origin.port ?? 0),
                modifierFlags: [], buttonNumber: 0, shouldPerformDownload: false, userInitiated: source["gesture"] == .bool(true))
            guard browser.letsWindow(from: page, for: action, parent: opener) else { return nil }
        }
        let configuration = Web.configuration(shy: privateMode, store: anchor.pageStore)
        let tab = Tab(shy: privateMode, bench: anchor.bench, configuration: configuration, engine: .chromium)
        // Install the inert handle before prepare/row observers can read
        // tab.page. Attach native events only after the tab has its space.
        guard let page = tab.prepareChromiumPageForAdoption(profile: profile) else { tab.close(); return nil }
        browser.prepare(tab)
        tab.opener = opener?.id; tab.from = opener?.id
        tab.assistantSpace = anchor.assistantSpace
        tab.agent = anchor.agent
        if let url = event.params["url"]?.string.flatMap(URL.init(string:)) { tab.setAddressOptimistically(url) }
        if browser.spaceID == space {
            if let index = extensionIndex(event.params, count: browser.tabs.count) {
                browser.insertPagePopup(tab, at: index)
            } else if let opener, browser.tabs.contains(where: { $0 === opener }) {
                browser.insertPagePopup(tab, at: browser.linkLanding(from: opener))
                tab.linkedFrom = opener.id
            } else { browser.appendPagePopup(tab) }
        } else {
            guard var parked = browser.parked[space] else { tab.close(); return nil }
            let index = extensionIndex(event.params, count: parked.tabs.count)
                ?? opener.flatMap { source in parked.tabs.firstIndex(where: { $0 === source }) }.map { $0 + 1 } ?? parked.tabs.count
            parked.tabs.insert(tab, at: index)
            browser.parked[space] = parked
        }
        guard tab.chromiumProfile == profile else {
            if browser.spaceID == space { browser.close(tab) } else { browser.closeElsewhere(tab) }
            return nil
        }
        page.adoptRemote(id)
        if browser.spaceID == space, event.params["foreground"] != .bool(false), !anchor.bench || browser.activeID == anchor.id {
            browser.activeID = tab.id
            browser.editing = false
        }
        return tab
    }

    /// Only native creation receipts authorize a new user-visible tab. An
    /// incidental default-client browser has no selection or placement intent.
    static func hasNativeRequest(_ params: [String: JSONValue]) -> Bool {
        switch params["creationPurpose"]?.string {
        case "popup":
            return params["opener"]?.string != nil && params["source"]?.object != nil
        case "extension":
            return params["extensionCreation"]?["extensionId"].string.map(ChromiumExtensions.validID) == true
        default: return false
        }
    }

    /// Only Chromium's extension-creation receipt can override Yab's normal
    /// link placement. Chrome clamps indexes beyond the end of a tab strip.
    static func extensionIndex(_ params: [String: JSONValue], count: Int) -> Int? {
        guard let receipt = params["extensionCreation"]?.object,
              let id = receipt["extensionId"]?.string, ChromiumExtensions.validID(id),
              let value = receipt["index"]?.number, value.isFinite,
              value >= 0, value.rounded() == value else { return nil }
        return Int(min(value, Double(max(0, count))))
    }
}
