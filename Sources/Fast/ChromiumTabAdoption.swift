import AppKit
import YabCoreClient

@MainActor enum ChromiumTabAdoption {
    /// No fallback to another profile or privacy mode. Native tabs have
    /// already loaded, so opening their URL again would destroy their identity.
    static func install(_ event: YabCoreEvent, opener: Tab?, owner: Tab? = nil) -> Tab? {
        if event.params["creationPurpose"]?.string == "notification" { return installFromNotice(event) }
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
        let identityProvider = isIdentityProvider(event.params)
        if event.params["extensionCreation"]?["requestedKind"] == .string("identity"), !identityProvider { return nil }
        let extensionWindow = isExtensionWindow(event.params)
        let pageWindow = isPageWindow(event.params) && !anchor.bench
        if event.params["extensionCreation"]?["requestedKind"] == .string("window"), !extensionWindow { return nil }
        let space = browser.spaceHolding(anchor) ?? browser.spaceID
        guard browser.spaceID == space || browser.parked[space] != nil else { return nil }
        // CEF permits an empty target for window.open(); it is the original
        // blank document, not an invalid creation request. Normalize once,
        // before WindowGate and placement examine the same native receipt.
        let requested = event.params["url"]?.string ?? ""
        let destination = URL(string: requested.isEmpty ? "about:blank" : requested)
        if let source = event.params["source"]?.object {
            guard let opener, let page = opener.builtPage,
                  let url = destination,
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
        // The first native navigation supplies the transition kind. A user
        // gesture alone also covers window.open(), which must stay open on Back.
        if returnsToSource(event.params) {
            page.popupBackSource = opener
            page.popupRequestedForeground = event.params["foreground"] != .bool(false)
            // The new native page did not receive the press itself. Keep
            // its original modifiers for the first action's Peek decision.
            // The native tab already exists; navigation must not replay them.
            page.lastPress = (opener?.builtPage as? ChromiumPage)?.lastPress.flatMap {
                ProcessInfo.processInfo.systemUptime - $0.at < 1 ? $0 : nil
            }
        }
        tab.assistantSpace = anchor.assistantSpace
        tab.agent = anchor.agent
        if let destination { tab.setAddressOptimistically(destination) }
        if identityProvider || extensionWindow || pageWindow {
            // Explicit page popup features use the same original-document
            // window ownership as sign-in windows. They never become Peek.
            // WebAuthFlow created a separate native provider window, or
            // windows.create({type: "popup"}) a window of the extension's
            // own (Bitwarden's pop-out, Duo inside it). The sign-in goes to
            // a Small Window, the extension's page to a plain window of its
            // own as Chromium's (ChromiumExtensionWindow), each preserving the
            // exact page and its caller instead of hiding/destroying the
            // action popup.
            tab.popup = true; tab.opener = anchor.id; tab.from = anchor.id
            if pageWindow { tab.scripted = Date() }
            browser.outside.append(tab)
            // WebAuthFlow closes this original WebContents on completion, an
            // extension its window with window.close() or windows.remove.
            // A Small Window is outside browser.tabs, so the ordinary tab
            // close route cannot remove its shell.
            page.onDocumentClosed = { [weak tab, weak browser] in
                guard let tab, !tab.gone else { return }
                FileHandle.standardError.write(Data("yab: popup window \(id) document closed\n".utf8))
                if let link = LinkWindow.all.first(where: { $0.tab === tab }) { link.close() }
                else if let made = ChromiumExtensionWindow.showing(tab) { made.close() }
                else if let browser {
                    // It may have been kept in the row while signing in.
                    if browser.tabs.contains(where: { $0 === tab }) { browser.close(tab) }
                    else { browser.closeElsewhere(tab) }
                }
            }
            page.adoptRemote(id)
            if identityProvider, let caller = anchor.builtPage as? ChromiumPage {
                ChromiumPopupHost.shared.preserveIdentityCaller(caller, provider: tab)
            }
            if identityProvider || pageWindow {
                let source = event.params["source"]
                let size = pageWindow ? NSSize(width: source?["width"].number ?? 480, height: source?["height"].number ?? 320) : nil
                LinkWindow.present(tab, for: browser, size: size)
            }
            else {
                ChromiumExtensionWindow.present(tab, for: browser, extension: event.params["extensionCreation"]?["extensionId"].string,
                                                from: anchor, size: extensionWindowSize(event.params))
            }
            FileHandle.standardError.write(Data("yab: tab \(id) adopted as \(identityProvider ? "identity" : pageWindow ? "page popup" : "extension") window\n".utf8))
            return tab
        }
        // Placement belongs to the native creation request, not the first
        // navigation's transition. window.open can start with about:blank or
        // a typed/script transition, and a redirect need not retain a gesture.
        // Decide before publishing a row or attaching events that can select it.
        if browser.spaceID == space, let opener, returnsToSource(event.params),
           event.params["foreground"] != .bool(false),
           let url = destination {
            let press = page.lastPress
            let action = PageAction(request: URLRequest(url: url), kind: .linkActivated,
                targetIsMainFrame: true, source: nil, modifierFlags: press?.flags ?? [],
                buttonNumber: press?.button ?? 0, shouldPerformDownload: false, userInitiated: true)
            if browser.peekAdoptedLink(tab, from: opener, action: action, atCreation: true) {
                page.adoptRemote(id)
                return tab
            }
        }
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
        let foreground = browser.spaceID == space && event.params["foreground"] != .bool(false)
            && (!anchor.bench || browser.activeID == anchor.id)
        let awaitsPlacement = page.popupBackSource != nil
        if foreground && awaitsPlacement { page.popupForegroundFrom = browser.activeID }
        page.adoptRemote(id)
        if foreground && !awaitsPlacement {
            browser.activeID = tab.id
            browser.editing = false
        }
        return tab
    }

    /// This native receipt is emitted only for Chromium's original WebAuthFlow.
    /// Neither a provider URL nor a recent extension click grants this route.
    static func isIdentityProvider(_ params: [String: JSONValue]) -> Bool {
        params["creationPurpose"] == .string("extension") &&
        params["extensionCreation"]?["requestedKind"] == .string("identity") &&
        params["extensionCreation"]?["ownerVersion"] == .number(1) &&
        params["extensionCreation"]?["ownerTab"].string?.isEmpty == false &&
        params["extensionCreation"]?["extensionId"].string.map(ChromiumExtensions.validID) == true
    }

    /// This native receipt is emitted only for Chromium's original
    /// windows.create of a popup window, never for tabs.create.
    static func isExtensionWindow(_ params: [String: JSONValue]) -> Bool {
        params["creationPurpose"] == .string("extension") &&
        params["extensionCreation"]?["requestedKind"] == .string("window") &&
        params["extensionCreation"]?["ownerVersion"] == .number(1) &&
        params["extensionCreation"]?["ownerTab"].string?.isEmpty == false &&
        params["extensionCreation"]?["extensionId"].string.map(ChromiumExtensions.validID) == true
    }

    /// The size windows.create asked for, both sides or neither, as a page
    /// that names its window size gets it. Its position is Yab's to choose.
    static func extensionWindowSize(_ params: [String: JSONValue]) -> NSSize? {
        guard isExtensionWindow(params),
              let width = params["extensionCreation"]?["requestedWidth"].number,
              let height = params["extensionCreation"]?["requestedHeight"].number,
              width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        return NSSize(width: width, height: height)
    }

    /// A worker's clients.openWindow() after a click on its notification,
    /// with no tab of the site left to open from: a tab in the space whose
    /// profile it is, in front, the person having just asked for it.
    private static func installFromNotice(_ event: YabCoreEvent) -> Tab? {
        guard let id = event.tab, let profile = event.params["profile"]?.string, event.params["private"] == .bool(false) else { return nil }
        for browser in BrowserWindows.shared.browsers {
            for space in browser.spaces {
                let store = Spaces.store(for: space.id)
                guard store.isPersistent, ChromiumPersistentProfiles.profile(store: store, placement: space.id) == profile else { continue }
                let tab = Tab(shy: false, configuration: Web.configuration(shy: false, store: store), engine: .chromium)
                guard let page = tab.prepareChromiumPageForAdoption(profile: profile) else { tab.close(); return nil }
                browser.prepare(tab)
                tab.assistantSpace = space.id
                if let url = event.params["url"]?.string.flatMap(URL.init(string:)) { tab.setAddressOptimistically(url) }
                if browser.spaceID == space.id {
                    browser.appendPagePopup(tab)
                } else if var parked = browser.parked[space.id] {
                    parked.tabs.append(tab)
                    browser.parked[space.id] = parked
                } else { tab.close(); return nil }
                page.adoptRemote(id)
                if browser.spaceID == space.id {
                    browser.activeID = tab.id
                    browser.editing = false
                }
                return tab
            }
        }
        return nil
    }

    /// Window intent is native metadata, never inferred from a destination URL
    /// or default dimensions (which ordinary new tabs also carry).
    static func isPageWindow(_ params: [String: JSONValue]) -> Bool {
        params["creationPurpose"] == .string("popup") &&
        params["source"]?["popup"] == .bool(true) &&
        params["source"]?["documentPiP"] != .bool(true)
    }

    static func returnsToSource(_ params: [String: JSONValue]) -> Bool {
        params["creationPurpose"] == .string("popup") &&
        params["source"]?["gesture"] == .bool(true) &&
        !isPageWindow(params) && params["source"]?["documentPiP"] != .bool(true)
    }

    /// Only native creation receipts authorize a new user-visible tab. An
    /// incidental default-client browser has no selection or placement intent.
    static func hasNativeRequest(_ params: [String: JSONValue]) -> Bool {
        switch params["creationPurpose"]?.string {
        case "popup":
            return params["opener"]?.string != nil && params["source"]?.object != nil
        case "extension":
            return params["extensionCreation"]?["extensionId"].string.map(ChromiumExtensions.validID) == true
        case "notification": return true
        default: return false
        }
    }

    /// A page of this profile in the window in front, for a tab nobody opened.
    static func frontTab(profile: String) -> Tab? {
        guard let browser = BrowserWindows.shared.activeBrowser else { return nil }
        if let tab = browser.active, tab.chromiumProfile == profile { return tab }
        return browser.tabs.first { $0.chromiumProfile == profile }
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
