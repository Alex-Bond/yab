import Foundation
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct LinkRouteEditorTests {
    @Test func actualEditorLoadsSavesAndReloadsWindowChoiceWhileRetainingSpace() throws {
        try #require(Store.testing)
        let routes = LinkRoutes.shared
        let editor = LinkRouteEditing.shared
        let site = "editor-" + UUID().uuidString.lowercased() + ".invalid"
        let renamed = "edited-" + site
        let home = UUID(), work = UUID()
        defer { editor.close(); routes.remove(site); routes.remove(renamed) }
        routes.set(site, to: work)
        editor.open(spaces: [], space: work, site: site)
        #expect(editor.draft?.opensInMain == false)
        editor.save(site: site, to: work, opensInMain: true)
        #expect(routes.route(site: site)?.space == work)
        #expect(routes.route(site: site)?.opensInMain == true)
        let url = try #require(URL(string: "https://\(site)/document"))
        #expect(LinkRoutes.opensInMain(routes.routes, for: url))
        #expect(LinkRoutes.destination(routes: routes.routes, for: url, available: [home, work], recent: home, fallback: nil) == work)
        editor.close()
        editor.open(spaces: [], space: work, site: site)
        #expect(editor.draft?.opensInMain == true)
        editor.save(site: renamed, to: work, opensInMain: true)
        #expect(routes.route(site: site) == nil)
        #expect(routes.route(site: renamed)?.space == work)
        #expect(routes.route(site: renamed)?.opensInMain == true)
        editor.close()
        editor.open(spaces: [], space: work, site: renamed)
        editor.save(site: renamed, to: work, opensInMain: false)
        let data = try #require(Store.settings.data(forKey: LinkRoutes.key))
        let persisted = try JSONDecoder().decode([LinkRoute].self, from: data)
        #expect(persisted.first { $0.site == renamed }?.space == work)
        #expect(persisted.first { $0.site == renamed }?.opensInMain == nil)
        #expect(!LinkRoutes.opensInMain(persisted, for: try #require(URL(string: "https://\(renamed)/document"))))
    }
}
