import Foundation
import WebKit

/// What a person added to pages, on a Chromium tab: boosts, userscripts and a
/// site's saved look. WebKit's content controller takes these one by one at
/// each navigation; a Chromium tab registers them as document-start scripts
/// that outlive a page's own navigations, so each keeps to its pages itself.
@MainActor
struct ChromiumAddons {
    typealias Route = @MainActor (PageScriptMessage, Tab, @escaping (Any?, String?) -> Void) -> Void
    var scripts: [PageScriptRegistration] = []
    /// By the world's name as the helper knows it.
    var relays: [String: [String]] = [:]
    var routes: [String: Route] = [:]
    var look: String?

    init() {}

    /// Every userscript and boost a person added: the helper takes any number
    /// of scripts, as Chromium does. Room for 128 less Yab's own dropped the rest.
    init(for tab: Tab) {
        let boosts = Boosts.shared.chromiumScripts(for: tab)
        scripts += boosts.scripts
        for id in boosts.relays {
            let world = ChromiumScripts.world(Boosts.pageWorld(id))
            relays[world] = ["yabBoostAPI"]
            routes[world] = { message, tab, reply in
                guard message.frame.isMain else { reply(nil, "Invalid plugin request."); return }
                BoostAPI.shared.heard(id: id, body: message.body, tab: tab, reply)
            }
        }
        let userscripts = Userscripts.shared.chromiumScripts(for: tab)
        scripts += userscripts.scripts
        for (id, inPage) in userscripts.relays {
            let world = ChromiumScripts.world(Userscripts.shared.pageWorld(id, inPage: false))
            relays[world] = ["yabUserscript"]
            routes[world] = { message, tab, reply in Userscripts.shared.heard(id, inPage: inPage, message: message, tab: tab, reply) }
        }
        look = Self.look(for: tab)
        if let look { scripts.append(PageScriptRegistration(source: look, world: .yab, atEnd: true, mainOnly: true)) }
    }

    static func look(for tab: Tab?) -> String? {
        guard let tab else { return nil }
        return BoostEditorLooks.shared.chromiumSource(for: tab)
    }
}
