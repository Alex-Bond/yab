import Foundation
import Testing
@testable import Fast

@MainActor
struct NetProfileRemovalTests {
    private func profile(_ id: String, name: String? = nil) -> NetThrottle {
        NetThrottle(id: id, name: name ?? id, latency: 125, download: 1200, upload: 300)
    }

    private func withPrefs(_ body: (NetPrefs, UserDefaults) -> Void) {
        let domain = "net-profile-removal-tests-" + UUID().uuidString
        let settings = UserDefaults(suiteName: domain)!
        defer { settings.removePersistentDomain(forName: domain) }
        body(NetPrefs(settings: settings), settings)
    }

    @Test func theOnlyRowsActionSurvivesItsOwnRemoval() {
        withPrefs { prefs, settings in
            prefs.profiles = [profile("last")]
            prefs.throttle = "last"
            // This is the production action created by the SwiftUI row,
            // before removal invalidates that row's collection index.
            let remove = prefs.profileRemovalAction(id: prefs.profiles[0].id)
            remove()
            #expect(prefs.profiles.isEmpty)
            #expect(prefs.throttle == NetThrottle.none.id)
            let reloaded = NetPrefs(settings: settings)
            #expect(reloaded.profiles.isEmpty)
            #expect(reloaded.throttle == NetThrottle.none.id)
        }
    }

    @Test func theActionKeepsItsIdentityAfterReorderingAndRenaming() {
        withPrefs { prefs, settings in
            let first = profile("first"), target = profile("target"), other = profile("other")
            prefs.profiles = [first, other, target]
            prefs.throttle = other.id
            let remove = prefs.profileRemovalAction(id: prefs.profiles[2].id)
            var renamed = target
            renamed.name = "Renamed after the row's action was made"
            prefs.profiles = [renamed, other, first]
            remove()
            #expect(prefs.profiles == [other, first])
            #expect(prefs.throttle == other.id)
            #expect(NetPrefs(settings: settings).profiles == [other, first])
        }
    }

    @Test func anActionForAnAlreadyRemovedRowIsSafeToRepeat() {
        withPrefs { prefs, settings in
            let keep = profile("keep"), target = profile("target")
            prefs.profiles = [keep, target]
            let remove = prefs.profileRemovalAction(id: prefs.profiles[1].id)
            prefs.profiles.removeLast()
            prefs.throttle = NetThrottle.fast4G.id
            remove()
            remove()
            #expect(prefs.profiles == [keep])
            #expect(prefs.throttle == NetThrottle.fast4G.id)
            #expect(NetPrefs(settings: settings).throttle == NetThrottle.fast4G.id)
        }
    }

    @Test(arguments: ["none", "fast4g", "keep"])
    func removingAMiddleRowPreservesAnotherSelection(_ selection: String) {
        withPrefs { prefs, settings in
            let first = profile("first"), target = profile("target"), keep = profile("keep")
            prefs.profiles = [first, target, keep]
            prefs.throttle = selection
            let remove = prefs.profileRemovalAction(id: prefs.profiles[1].id)
            remove()
            #expect(prefs.profiles == [first, keep])
            #expect(prefs.throttle == selection)
            let reloaded = NetPrefs(settings: settings)
            #expect(reloaded.profiles == [first, keep])
            #expect(reloaded.throttle == selection)
        }
    }

    @Test func injectedPreferencesKeepTheirExistingPersistenceContract() {
        withPrefs { prefs, settings in
            prefs.userAgent = "Own network fixture"
            prefs.saveData = "on"
            prefs.keepLog = true
            prefs.addProfile()
            let reloaded = NetPrefs(settings: settings)
            #expect(reloaded.userAgent == "Own network fixture")
            #expect(reloaded.saveData == "on")
            #expect(reloaded.keepLog)
            #expect(reloaded.profiles == prefs.profiles)
            #expect(reloaded.profiles.count == 1)
            prefs.userAgent = nil
            prefs.saveData = nil
            let cleared = NetPrefs(settings: settings)
            #expect(cleared.userAgent == nil)
            #expect(cleared.saveData == nil)
        }
    }
}
