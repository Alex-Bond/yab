import AppKit

extension Bench {
    /// Windows a page asks for (WindowGate) and the corner that offers a
    /// broken page its ads back (Unbreak), driven and read. A --test run
    /// only: it clicks in pages and changes what sites are allowed.
    ///
    /// act: "person" (url) a tab of yours in front → its id; "state" (id)
    /// what the tab's page was kept from, the sites allowed, its Site
    /// Controls rows, the tab in front and the corner's words; "click" (id,
    /// selector) a real click of the mouse on the element's middle, as
    /// mouse events; "type" (id, selector, text) a real press and text insertion; "menu" (id) the chip's rows; "pick" (id, index) one of
    /// them chosen; "popup" (id) the chip's menu up for a picture, "dismiss"
    /// takes it down; "forget" (site); "reload" (id) as ⌘R; "take" the
    /// corner's button pressed; "unbreak" the corner's limit, "unbreak-reset"
    /// it cleared.
    func windowsCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "windows only works on a --test run"]); return }
        let act = request["act"] as? String ?? "state"
        let tab = find(request, in: browser)
        switch act {
        case "person":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else { answer(["error": "person needs a url"]); return }
            answer(["id": Bench.short(browser.open(url, foreground: true))])
        case "state":
            guard let tab else { answer(missing(request)); return }
            let rows = SiteFacts(tab: tab).allowed.map { "\($0.title): \($0.said ? "Allowed" : "Blocked")" }
            answer([
                "blocked": tab.windows.blocked.map { $0.url?.absoluteString ?? "" },
                "visit": tab.windows.visit,
                "allowed": WindowGate.allowed.sorted(),
                "rows": rows,
                "active": browser.active.map(Bench.short) ?? "",
                "activeURL": browser.active?.address?.absoluteString ?? "",
                "tabs": browser.tabs.count,
                "toast": browser.toaster.shown ? browser.toaster.words : "",
                "toastAct": browser.toaster.shown ? browser.toaster.act ?? "" : "",
                "blockedPage": Unbreak.shared.blockedPage(tab, at: tab.builtPage?.url),
            ])
        case "click", "type":
            guard let tab, let selector = request["selector"] as? String else { answer(missing(request)); return }
            house(tab)
            let script = "(() => { const r = document.querySelector(\(Bench.quoted(selector)))?.getBoundingClientRect(); return r ? [r.left + r.width / 2, r.top + r.height / 2] : null })()"
            let page = tab.page
            page.run(script, gesture: false) { [weak tab, weak page] result in
                guard let tab, let page, tab.builtPage === page,
                      case .success(let value) = result, let at = value as? [Double], at.count == 2,
                      PageBenchInput.click(page, x: at[0], y: at[1]) else {
                    answer(["error": "nothing at \(selector)"])
                    return
                }
                if act == "type", !PageBenchInput.type(request["text"] as? String ?? "", into: page) {
                    answer(["error": "page cannot receive text"])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    answer(["clicked": selector, "input": page.lastInput != nil])
                }
            }
        case "menu":
            guard let tab else { answer(missing(request)); return }
            answer(["rows": BlockedMenu.make(for: tab, in: browser).items.map(\.title)])
        case "pick":
            guard let tab else { answer(missing(request)); return }
            let menu = BlockedMenu.make(for: tab, in: browser)
            let index = request["index"] as? Int ?? 0
            guard menu.items.indices.contains(index) else { answer(["error": "no row \(index)"]); return }
            let title = menu.items[index].title
            menu.performActionForItem(at: index)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(["picked": title]) }
        case "popup":
            guard let tab else { answer(missing(request)); return }
            guard let anchor = WindowBench.anchor(in: tab.page.window?.contentView) else { answer(["error": "no chip on screen"]); return }
            // The menu holds the run loop while it is up; the answer comes
            // from inside it, with the menu's own window, for a picture.
            // Opened from the run loop, not the main queue: a menu tracking
            // inside a main-queue block holds the queue too, and the answer
            // waited behind it until the menu went (the eval timed out).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                answer(["up": BlockedMenu.shown != nil, "windows": WindowBench.menuWindows()])
            }
            RunLoop.main.perform(inModes: [.default]) {
                MainActor.assumeIsolated { BlockedMenu.show(for: tab, in: browser, under: anchor) }
            }
        case "dismiss":
            BlockedMenu.shown?.cancelTracking()
            ActionMenu.close()
            answer(["ok": true])
        case "forget":
            guard let site = request["site"] as? String else { answer(["error": "forget needs a site"]); return }
            WindowGate.forget(site)
            answer(["allowed": WindowGate.allowed.sorted()])
        case "reload":
            guard let tab else { answer(missing(request)); return }
            browser.reload(tab)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["toast": browser.toaster.shown ? browser.toaster.words : "", "paused": Shield.shared.isPaused(on: tab.address?.host())])
            }
        case "take":
            let words = browser.toaster.shown ? browser.toaster.words : ""
            browser.toaster.undone()
            answer(["took": words])
        case "unbreak":
            let limit = Unbreak.shared.limit
            answer(["ignored": limit.ignored, "quietUntil": limit.quietUntil?.timeIntervalSince1970 ?? 0])
        case "unbreak-reset":
            Unbreak.shared.limit = UnbreakLimit()
            answer(["ok": true])
        default:
            answer(["error": "windows act: person, state, click, type, menu, pick, popup, dismiss, forget, reload, take, unbreak, unbreak-reset"])
        }
    }

    static func quoted(_ text: String) -> String {
        (try? String(data: JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
    }
}

@MainActor
enum WindowBench {
    /// This app's windows over the normal ones, a menu's among them.
    static func menuWindows() -> [Int] {
        let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let me = Int(ProcessInfo.processInfo.processIdentifier)
        return all.compactMap { entry in
            guard entry[kCGWindowOwnerPID as String] as? Int == me,
                  (entry[kCGWindowLayer as String] as? Int ?? 0) > 0 else { return nil }
            return entry[kCGWindowNumber as String] as? Int
        }
    }

    /// The view under the chip, found by its name: the menu hangs from it
    /// as it does from a press.
    static func anchor(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view.identifier?.rawValue == WindowChip.anchorID { return view }
        for sub in view.subviews { if let found = anchor(in: sub) { return found } }
        return nil
    }
}
