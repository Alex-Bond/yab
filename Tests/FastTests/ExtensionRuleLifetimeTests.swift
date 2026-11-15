import AppKit
import Testing
import WebKit
@testable import Fast

/// The production install/disable paths own the rules bridge, including a
/// context WebKit refuses before it can enter Extensions.contexts.
@MainActor
@Suite(.serialized)
struct ExtensionRuleLifetimeTests {
    @MainActor
    private final class Fixture {
        let owner: Extensions
        let root: URL
        var ids: [String] = []
        var injected: [WKWebExtensionContext] = []

        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent("rule-lifetime-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            owner = Extensions(signIn: nil)
        }

        func nextID() -> String {
            "lifetime" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }

        func source(rules: Bool) throws -> URL {
            let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let manifest = rules ? #"{"manifest_version":3,"name":"Rule lifetime","version":"1.0","permissions":["declarativeNetRequest"],"host_permissions":["<all_urls>"],"declarative_net_request":{"rule_resources":[{"id":"one","enabled":true,"path":"rules.json"}]}}"#
                : #"{"manifest_version":3,"name":"Base URL owner","version":"1.0"}"#
            try manifest.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            if rules {
                try #"[{"id":1,"action":{"type":"block"},"condition":{"urlFilter":"/rule-lifetime.gif","resourceTypes":["image"]}}]"#
                    .write(to: folder.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
            }
            return folder
        }

        func admit(_ id: String) async throws -> Bool {
            ids.append(id)
            let staged = try source(rules: true)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let grants = Extensions.grants(found, in: staged)
            // An already-approved synced arrival takes the same production
            // load path without an installation or blocker-choice question.
            return try await owner.admit(staged, as: id, fromStore: false,
                                         finalFolder: Extensions.folder(for: id), confirm: false, quiet: true,
                                         synced: .init(enabled: true, pinned: false, allowed: grants))
        }

        func occupying(_ id: String) async throws -> WKWebExtensionContext {
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: source(rules: false)))
            context.uniqueIdentifier = nextID()
            context.baseURL = try #require(URL(string: "\(Extensions.scheme)://\(id)/"))
            try owner.controller.load(context)
            injected.append(context)
            try #require(context.isLoaded)
            try #require(owner.controller.extensionContext(for: context.baseURL) === context)
            return context
        }

        func waitForHeld(_ id: String) async throws {
            for _ in 0..<100 {
                if ExtensionRules.report(id)["held"] as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(ExtensionRules.report(id)["held"] as? Bool == true)
        }

        func cleanUp() {
            for context in injected { try? owner.controller.unload(context) }
            for id in ids {
                owner.remove(id)
                // Parent failures deliberately leave a registration behind;
                // cleanup is after all observations, never their substitute.
                ExtensionRules.forget(id)
            }
            owner.shutDown()
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test func failedProductionLoadReleasesPreparedRules() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = fixture.nextID()
        let occupant = try await fixture.occupying(id)

        // Verify the real engine refusal independently of the app's Bool
        // result. The public SDK defines baseURLAlreadyInUse for this case.
        let collision = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: fixture.source(rules: false)))
        collision.uniqueIdentifier = fixture.nextID()
        collision.baseURL = occupant.baseURL
        var refusal: NSError?
        do { try fixture.owner.controller.load(collision) }
        catch { refusal = error as NSError }
        if collision.isLoaded { try? fixture.owner.controller.unload(collision) }
        let error = try #require(refusal)
        try #require(error.domain == WKWebExtensionContext.errorDomain)
        try #require(error.code == WKWebExtensionContext.Error.baseURLAlreadyInUse.rawValue)

        let loaded = try await fixture.admit(id)
        try #require(!loaded)
        try #require(fixture.owner.installed.contains { $0.id == id && $0.enabled })
        try #require(fixture.owner.contexts[id] == nil)
        try #require(occupant.isLoaded)
        try #require(fixture.owner.controller.extensionContext(for: occupant.baseURL) === occupant)
        #expect(ExtensionRules.report(id).isEmpty)
        // A failed load can already have scheduled an asynchronous lookup.
        // Turning it off must leave neither that lookup nor its watcher live.
        fixture.owner.setEnabled(id, false)
        try await Task.sleep(for: .milliseconds(150))
        #expect(ExtensionRules.report(id).isEmpty)
        #expect(!ExtensionRules.holds(id))
        #expect(occupant.isLoaded)
    }

    @Test func successfulDisablePreservesSiblingRules() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let first = fixture.nextID()
        let sibling = fixture.nextID()
        let firstLoaded = try await fixture.admit(first)
        let siblingLoaded = try await fixture.admit(sibling)
        try #require(firstLoaded && siblingLoaded)
        let firstContext = try #require(fixture.owner.contexts[first])
        let siblingContext = try #require(fixture.owner.contexts[sibling])
        try #require(firstContext.isLoaded && siblingContext.isLoaded)
        try await fixture.waitForHeld(first)
        try await fixture.waitForHeld(sibling)
        try #require(!ExtensionRules.report(first).isEmpty)
        try #require(!ExtensionRules.report(sibling).isEmpty)

        fixture.owner.setEnabled(first, false)
        #expect(fixture.owner.contexts[first] == nil)
        #expect(!firstContext.isLoaded)
        #expect(ExtensionRules.report(first).isEmpty)
        #expect(!ExtensionRules.holds(first))
        #expect(fixture.owner.contexts[sibling] === siblingContext)
        #expect(siblingContext.isLoaded)
        #expect(ExtensionRules.holds(sibling))
        #expect(!ExtensionRules.report(sibling).isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(ExtensionRules.report(first).isEmpty)
        #expect(ExtensionRules.holds(sibling))
    }

    @Test func missingContextDisableAndRemoveReleasePreparedRules() async throws {
        for removing in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let id = fixture.nextID()
            let occupant = try await fixture.occupying(id)
            let loaded = try await fixture.admit(id)
            try #require(!loaded)
            try #require(fixture.owner.contexts[id] == nil)
            try fixture.owner.controller.unload(occupant)

            // Establish an owned, genuinely loaded context without registering
            // it in the manager's dictionary. Preparing after load uses the old
            // API on both trees and lets the candidate infer its real controller.
            let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: Extensions.folder(for: id)))
            context.uniqueIdentifier = id
            context.baseURL = occupant.baseURL
            for permission in context.webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
            try fixture.owner.controller.load(context)
            fixture.injected.append(context)
            try #require(context.isLoaded)
            let storage = try #require(fixture.owner.storage(of: id))
            ExtensionRules.prepare(context, storage: storage)
            try await fixture.waitForHeld(id)
            try #require(fixture.owner.contexts[id] == nil)
            try #require(!ExtensionRules.report(id).isEmpty)

            if removing { fixture.owner.remove(id) }
            else { fixture.owner.setEnabled(id, false) }
            #expect(ExtensionRules.report(id).isEmpty)
            #expect(!ExtensionRules.holds(id))
            // This cleanup is specifically for the prepared bridge; it must not
            // pretend a context absent from the manager was unloaded by it.
            #expect(context.isLoaded)
            try await Task.sleep(for: .milliseconds(150))
            #expect(ExtensionRules.report(id).isEmpty)
            #expect(!ExtensionRules.holds(id))
        }
    }

    @Test func unrelatedControllerCannotReleaseLoadedRules() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let id = fixture.nextID()
        let loaded = try await fixture.admit(id)
        try #require(loaded)
        let context = try #require(fixture.owner.contexts[id])
        try await fixture.waitForHeld(id)

        // A second manager reads the installed item but has never loaded it.
        // Its nil-context unload must not release the first controller's list.
        let unrelated = Extensions(signIn: nil)
        defer { unrelated.shutDown() }
        try #require(unrelated.controller !== fixture.owner.controller)
        try #require(unrelated.installed.contains { $0.id == id })
        try #require(unrelated.contexts[id] == nil)
        unrelated.setEnabled(id, false)
        #expect(context.isLoaded)
        #expect(fixture.owner.contexts[id] === context)
        #expect(ExtensionRules.holds(id))
        #expect(!ExtensionRules.report(id).isEmpty)
        try await Task.sleep(for: .milliseconds(150))
        #expect(ExtensionRules.holds(id))
        #expect(!ExtensionRules.report(id).isEmpty)
    }
}
