import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct AddonProfilesTests {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("addon-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    @Test func migrationPreservesExistingProfilesButDoesNotAdoptNewOnes() throws {
        let work = UUID(), fresh = UUID()
        var profiles = AddonProfiles(legacy: true, signIns: [work])
        #expect(profiles.isEnabled(in: nil))
        #expect(profiles.isEnabled(in: work))
        #expect(!profiles.contains(fresh))
        profiles.setEnabled(false, in: work)
        #expect(profiles.isEnabled(in: nil))
        #expect(!profiles.isEnabled(in: work))
        let decoded = try JSONDecoder().decode(AddonProfiles.self, from: JSONEncoder().encode(profiles))
        #expect(decoded == profiles)
    }
    @Test func sharedSpacesResolveToTheSameProfileAsTheirTabs() {
        let space = UUID()
        let browser = Browser(windowID: UUID())
        defer { browser.letGo() }
        // Browser restores the saved routing at birth; set the fixture after it.
        Spaces.sharing.insert(space)
        defer { Spaces.sharing.remove(space) }
        browser.spaceID = space
        let tab = Tab(bench: true, configuration: Web.configuration(store: Spaces.store(for: space)))
        #expect(AddonProfiles.of(browser) == nil)
        #expect(AddonProfiles.of(tab) == nil)
    }
    @Test func updatingAndRemovingABoostKeepsOtherProfiles() async throws {
        let root = try root(), work = UUID(), other = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BoostLibrary(root: root)
        let package = try BoostPackage.read(id: "profile-calm", files: BoostTests.files(), sites: ["example.com"])
        var profiles = AddonProfiles(signIn: work, enabled: true)
        profiles.setEnabled(true, in: other)
        _ = try library.keep(package, author: "You", session: "", profiles: profiles)
        _ = try library.keep(package, author: "You", session: "")
        let boosts = Boosts(root: root, safeMode: false)
        #expect(boosts.records(in: nil).isEmpty)
        #expect(boosts.isEnabled(package.id, in: work))
        await boosts.setEnabled(package.id, false, in: work)
        #expect(!boosts.isEnabled(package.id, in: work))
        #expect(boosts.isEnabled(package.id, in: other))
        await boosts.delete(package.id, in: work)
        #expect(boosts.records(in: work).isEmpty)
        #expect(boosts.isEnabled(package.id, in: other))
        #expect(FileManager.default.fileExists(atPath: library.folder(package.id).path))
        await boosts.delete(package.id, in: other)
        #expect(boosts.records.isEmpty)
    }
    @Test func userscriptValuesSwitchesAndRemovalAreIndependent() throws {
        let root = try root(), work = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = Userscripts(root: root)
        let script = try Userscript.read(UserscriptTests.script(["@name Values", "@namespace profiles", "@match https://example.com/*", "@grant GM_getValue"]))
        var profiles = AddonProfiles(signIn: nil, enabled: true)
        profiles.setEnabled(true, in: work)
        try scripts.store(script, source: nil, enabled: true, values: ["marker": "shared-only"], profiles: profiles)
        let file = scripts.valuesFile(script.id, in: work)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["marker": "work-only"]).write(to: file)
        #expect(scripts.values(of: script.id)["marker"] as? String == "shared-only")
        #expect(scripts.values(of: script.id, in: work)["marker"] as? String == "work-only")
        let sharedSource = scripts.source(script, id: script.id, inPage: false)
        let workSource = scripts.source(script, id: script.id, inPage: false, signIn: work)
        #expect(sharedSource.contains("shared-only") && !sharedSource.contains("work-only"))
        #expect(workSource.contains("work-only") && !workSource.contains("shared-only"))
        scripts.setEnabled(script.id, false, in: work)
        #expect(scripts.isEnabled(script.id, in: nil))
        #expect(!scripts.isEnabled(script.id, in: work))
        // An ordinary version update keeps both installations and their switches.
        try scripts.store(script, source: nil, enabled: true)
        scripts.delete(script.id, in: work)
        #expect(scripts.records(in: work).isEmpty)
        #expect(scripts.isEnabled(script.id, in: nil))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let reloaded = Userscripts(root: root)
        #expect(reloaded.records(in: work).isEmpty)
        #expect(reloaded.values(of: script.id)["marker"] as? String == "shared-only")
    }
    @Test func sharedSyncDoesNotTurnOffOrRemoveAnOwnProfileInstallation() async throws {
        let root = try root(), work = UUID()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try BoostPackage.read(id: "profile-sync", files: BoostTests.files(), sites: ["example.com"])
        let boosts = Boosts(root: root, safeMode: false)
        try boosts.keepSynced(package, author: "You")
        await boosts.setEnabled(package.id, true, in: work)
        boosts.applySynced(package.id, enabled: false, runsOn: nil)
        #expect(!boosts.isEnabled(package.id, in: nil))
        #expect(boosts.isEnabled(package.id, in: work))
        boosts.removeSynced(package.id)
        #expect(boosts.records(in: nil).isEmpty)
        #expect(boosts.isEnabled(package.id, in: work))
        #expect(boosts.records.first?.runs(on: "local", syncing: true) == true)
    }

    @Test func pluginPageStorageDoesNotCrossProfiles() throws {
        let id = "profile-storage-" + UUID().uuidString, work = UUID()
        defer {
            Store.settings.removeObject(forKey: BoostStorage.key(id))
            Store.settings.removeObject(forKey: BoostStorage.key(BoostStorage.scopedID(id, in: work)))
        }
        try BoostStorage.set(id, ["marker": "shared"], in: nil)
        #expect(BoostStorage.get(id, in: work).isEmpty)
        try BoostStorage.set(id, ["marker": "work"], in: work)
        #expect(BoostStorage.get(id, in: nil)["marker"] as? String == "shared")
        #expect(BoostStorage.get(id, in: work)["marker"] as? String == "work")
    }
}
