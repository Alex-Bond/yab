import Foundation
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

extension StateCatalog {
    /// Real public icon bytes, isolated from the person's profile and network.
    static let siteIcons: [NamedState] = ["pins", "folder", "tabs", "field", "history", "mac"].map { mode in
        NamedState("icons." + mode, "Site icons: " + mode, "Six real public site icons from the icon-proof world.") { app in
            guard app.world.name == "icon-proof" else { return }
            struct Fixture: Decodable {
                struct Icon: Decodable { let host: String; let data: Data }
                let icons: [Icon]
            }
            guard let file = World.folder?.appendingPathComponent("icon-proof.json"),
                  let data = try? Data(contentsOf: file), let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else { return }
            let decoder = SiteIcons(accepts: { _ in false })
            var icons: [SyncIcon] = []
            for (index, entry) in fixture.icons.enumerated() {
                guard let image = await decoder.decodeIcon(entry.data) else { continue }
                let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
                let pixels = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 128), format: format).pngData { _ in
                    image.draw(in: CGRect(x: 0, y: 0, width: 128, height: 128))
                }
                if let icon = SyncIcon(Record(collection: SyncCollection.icon, id: "site-proof-\(index).png",
                    fields: ["data": .string(pixels.base64EncodedString()), "origin": .string("https://" + entry.host)])) {
                    icons.append(icon)
                }
            }
            app.sync.folderArtwork.replace(account: "site-icon-proof", icons: icons)
            switch mode {
            case "history":
                app.history.fixtureVisits = app.browser.space.today.map { tab in
                    BrowserVisit(url: tab.url!, title: tab.title, site: tab.site, icon: tab.icon,
                                 host: tab.addressHost, visitedAt: Date(), count: 1)
                }
                app.showHistory()
            case "tabs":
                app.surfaces.closeField()
                let stack = TabStack.of(app)
                for tab in app.browser.space.today { stack.touch(tab.id, in: app.browser.spaceID) }
                stack.openGallery()
                try? await Task.sleep(for: .seconds(1))
            case "mac":
                let rows = app.browser.space.today.map { (url: $0.url!, title: $0.title) }
                var space = app.browser.space
                space.pins = []; space.kept = []; space.today = []; space.current = nil
                app.browser.adopt([space])
                SettingsStore.shared.macTabs = true
                app.sync.pretendMacToday(rows, in: space.id)
                let now = Date()
                let front = SyncPresence(device: "mac", name: "MacBook Pro", at: now.timeIntervalSince1970,
                                         url: rows.last?.url, title: rows.last?.title, tab: "mac-work-5", asleep: false)
                app.sync.pretendMacs([SyncMac(id: "mac", name: "MacBook Pro", model: "Mac16,1", lastSeen: now,
                                            online: true, front: front, state: .up, usedAt: now)])
                NewTabPager.shared.startAt = space.id
                app.field.openSpaces()
            case "folder":
                var space = app.browser.space
                space.pins = []; space.today = []
                space.current = space.keptTabs.last?.id
                app.browser.adopt([space])
                app.surfaces.openField(.newTab)
            case "field":
                app.surfaces.openField(.newTab)
                app.field.typed("yo")
            default:
                app.surfaces.openField(.newTab)
            }
        }
    }
}
