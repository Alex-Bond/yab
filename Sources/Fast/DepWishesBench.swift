import AppKit
import SwiftUI

// Test-world access to the same route editor and tab context menu a person
// uses, so their words and shortcuts can be checked on the built app.
extension Bench {
    private static var wishesMenu: NSMenu?
    private static var wishesMenuOpening: Timer?
    private static var wishesMenuWatchdog: Timer?
    private static var wishesMenuGeneration = UUID()

    private static func closeWishesMenu() {
        wishesMenuGeneration = UUID()
        wishesMenuOpening?.invalidate()
        wishesMenuOpening = nil
        wishesMenuWatchdog?.invalidate()
        wishesMenuWatchdog = nil
        wishesMenu?.cancelTracking()
        wishesMenu = nil
    }

    func depWishesCommand(_ verb: String, _ request: [String: Any], browser: Browser,
                          _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "\(verb) only works on a --test run"]); return }
        let act = request["act"] as? String ?? "read"
        if verb == "link-routes" {
            let routes = LinkRoutes.shared
            let space = (request["space"] as? String).flatMap { name in
                browser.spaces.first { $0.name.lowercased() == name.lowercased() }
            }?.id ?? browser.spaceID
            if let small = request["small"] as? Bool { browser.prefs.smallLinks = small }
            switch act {
            case "set", "remove":
                guard let typed = request["site"] as? String, let site = LinkRoutes.site(from: typed)
                else { answer(["error": "invalid site, word or pattern"]); return }
                if act == "set" { routes.set(site, to: space) } else { routes.remove(site) }
            case "card":
                SettingsWindow.shared.show(.spaces, for: browser)
                LinkRouteEditing.shared.open(spaces: browser.spaces, space: space)
            case "edit":
                // The card a click on the rule's row opens, its text in the field.
                guard let typed = request["site"] as? String, let site = LinkRoutes.site(from: typed),
                      let route = routes.route(site: site)
                else { answer(["error": "no rule for that site"]); return }
                SettingsWindow.shared.show(.spaces, for: browser)
                LinkRouteEditing.shared.open(spaces: browser.spaces, space: route.space, site: route.site)
            case "close": LinkRouteEditing.shared.close()
            default: break
            }
            answer(["routes": routes.routes.map { route in
                ["site": route.site, "space": browser.spaces.first { $0.id == route.space }?.name ?? ""]
            }])
            return
        }

        if act == "close" {
            Self.closeWishesMenu()
            answer(["closed": true])
            return
        }
        guard let key = request["id"] as? String,
              let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(key.lowercased()) }),
              let window = Links.window, window.contentView != nil
        else { answer(["error": "tab-menu needs a tab and browser window"]); return }
        Self.closeWishesMenu()
        // The menu a right-click on the row opens (SteadyMenu.swift).
        let menu: NSMenu = NSHostingMenu(rootView: TabMenu(browser: browser, tab: tab, close: { browser.close(tab) }))
        menu.appearance = window.effectiveAppearance
        Self.wishesMenu = menu
        menu.update()
        ActionMenu.prepare(menu)
        if act == "pick" {
            // An item chosen, as a click on it would: "title" names it, a
            // submenu's as "Submenu/Item".
            guard let title = request["title"] as? String else { Self.closeWishesMenu(); answer(["error": "pick needs a title"]); return }
            var within = menu
            var name = title
            if !menu.items.contains(where: { $0.title == title }), let slash = title.firstIndex(of: "/"),
               let sub = menu.items.first(where: { $0.title == String(title[..<slash]) })?.submenu {
                sub.update()
                within = sub
                name = String(title[title.index(after: slash)...])
            }
            guard let index = within.items.firstIndex(where: { $0.title == name }), within.items[index].isEnabled
            else { Self.closeWishesMenu(); answer(["error": "no enabled item named \(title)"]); return }
            within.performActionForItem(at: index)
            Self.closeWishesMenu()
            answer(["picked": title])
            return
        }
        // A submenu's items after it, as "Submenu/Item".
        answer(["items": menu.items.filter { !$0.isSeparatorItem }.flatMap { item -> [[String: Any]] in
            var rows: [[String: Any]] = [["title": item.title, "enabled": item.isEnabled]]
            if let sub = item.submenu {
                sub.update()
                rows += sub.items.filter { !$0.isSeparatorItem }.map { ["title": item.title + "/" + $0.title, "enabled": $0.isEnabled] }
            }
            return rows
        }])
        if act == "show" {
            // Menu tracking runs a nested event loop. Enter it outside a
            // main-dispatch block so the bench's main-queue socket sources
            // can still answer the capture and close requests.
            let generation = Self.wishesMenuGeneration
            // "around": the row by that title put under the point, so a
            // long menu on a short screen shows it rather than scrolling.
            let around = (request["around"] as? String).flatMap { title in menu.items.first { $0.title == title } }
            let opening = Timer(timeInterval: 0.01, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard Self.wishesMenuGeneration == generation,
                          let menu = Self.wishesMenu, let content = Links.window?.contentView else { return }
                    Self.wishesMenuOpening = nil
                    let watchdog = Timer(timeInterval: 10, repeats: false) { _ in
                        MainActor.assumeIsolated {
                            guard Self.wishesMenuGeneration == generation else { return }
                            Self.closeWishesMenu()
                        }
                    }
                    Self.wishesMenuWatchdog = watchdog
                    RunLoop.main.add(watchdog, forMode: .common)
                    menu.popUp(positioning: around, at: NSPoint(x: 180, y: around == nil ? content.bounds.height - 90 : content.bounds.height / 2), in: content)
                    if Self.wishesMenuGeneration == generation {
                        Self.wishesMenuWatchdog?.invalidate()
                        Self.wishesMenuWatchdog = nil
                    }
                }
            }
            Self.wishesMenuOpening = opening
            RunLoop.main.add(opening, forMode: .common)
        }
    }
}
