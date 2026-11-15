import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

/// Real registered contexts and production access mutations, without pages,
/// workers, network requests or synthetic WebKit permission responses.
@MainActor
@Suite(.serialized)
struct ExtensionSiteAccessTests {
    @MainActor
    private final class Fixture {
        let signIn = UUID()
        let id = "siteaccess" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root: URL
        let owner: Extensions
        let savedPrivate: Any?

        init() throws {
            try #require(Store.testing)
            _ = NSApplication.shared
            savedPrivate = Store.settings.object(forKey: "extensions.private")
            root = FileManager.default.temporaryDirectory.appendingPathComponent("site-access-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            Store.settings.set(false, forKey: "extensions.private")
            owner = Extensions(signIn: signIn)
        }

        func load() async throws -> WKWebExtensionContext {
            let staged = root.appendingPathComponent("staged", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try #"{"manifest_version":3,"name":"Site access contract","version":"1.0","host_permissions":["https://required.example/*"],"optional_host_permissions":["*://blocked.example/*","*://*.blocked.example/*","*://allowed.example/*","*://*.allowed.example/*","*://other.example/*"]}"#
                .write(to: staged.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
            let found = try await WKWebExtension(resourceBaseURL: staged)
            let grants = Extensions.grants(found, in: staged)
            let loaded = try await owner.admit(staged, as: id, fromStore: false,
                                               finalFolder: Extensions.folder(for: id), confirm: false, quiet: true,
                                               synced: .init(enabled: true, pinned: false, allowed: grants))
            try #require(loaded)
            let context = try #require(owner.contexts[id])
            try #require(context.isLoaded)
            try #require(context.webExtensionController === owner.controller)
            try #require(owner.controller.extensionContext(for: context.baseURL) === context)
            try #require(owner.store.identifier == signIn)
            try #require(owner.access(id) == .asked)
            try trace("fixture-ready", context: context)
            return context
        }

        func trace(_ event: String, context: WKWebExtensionContext,
                   patterns: [WKWebExtension.MatchPattern] = [], urls: [URL] = []) throws {
            let record: [String: Any] = [
                "event": event, "id": id, "loaded": context.isLoaded,
                "controllerMatches": context.webExtensionController === owner.controller,
                "registered": owner.controller.extensionContext(for: context.baseURL) === context,
                "storeID": owner.store.identifier?.uuidString ?? "", "expectedStoreID": signIn.uuidString,
                "access": owner.access(id).rawValue, "privateAccess": context.hasAccessToPrivateData,
                "patterns": patterns.map { pattern -> [String: Any] in
                    ["pattern": pattern.string, "status": context.permissionStatus(for: pattern).rawValue]
                },
                "urls": urls.map { url -> [String: Any] in
                    ["url": url.absoluteString, "allowed": context.hasAccess(to: url)]
                }
            ]
            print("EXTENSION_SITE_ACCESS_NATIVE " + String(decoding: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), as: UTF8.self))
        }

        func cleanUp() {
            owner.remove(id)
            owner.shutDown()
            if let savedPrivate { Store.settings.set(savedPrivate, forKey: "extensions.private") }
            else { Store.settings.removeObject(forKey: "extensions.private") }
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: Extensions.signIns.appendingPathComponent(signIn.uuidString, isDirectory: true))
        }
    }

    @Test func anExplicitBlockedHostSurvivesALaterOptionalGrant() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        let patterns = Extensions.patterns(for: "blocked.example")
        try #require(patterns.count == 2)
        fixture.owner.block("blocked.example", for: fixture.id)
        for pattern in patterns {
            try #require(context.permissionStatus(for: pattern) == .deniedExplicitly)
        }
        let root = URL(string: "https://blocked.example/page")!
        let child = URL(string: "https://child.blocked.example/page")!
        try #require(!context.hasAccess(to: root) && !context.hasAccess(to: child))
        try fixture.trace("before-give", context: context, patterns: patterns, urls: [root, child])

        // Both exact denied patterns are requested, so another overlapping
        // denial cannot hide the effect of granting one of them directly.
        fixture.owner.give(sites: patterns, to: context)
        try fixture.trace("after-give", context: context, patterns: patterns, urls: [root, child])

        for pattern in patterns {
            #expect(context.permissionStatus(for: pattern) == .deniedExplicitly)
        }
        #expect(!context.hasAccess(to: root))
        #expect(!context.hasAccess(to: child))
        #expect(fixture.owner.blocked(fixture.id) == ["blocked.example"])
    }

    @Test func permittedOptionalGrantPreservesRequiredAccessAndPrivateBoundary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        let allowed = URL(string: "https://allowed.example/page")!
        let required = URL(string: "https://required.example/page")!
        try #require(context.hasAccess(to: required))
        try #require(!context.hasAccess(to: allowed))
        try #require(!context.hasAccessToPrivateData)

        fixture.owner.give(sites: Extensions.patterns(for: "allowed.example"), to: context)

        #expect(context.hasAccess(to: allowed))
        #expect(context.hasAccess(to: required))
        #expect(!context.hasAccess(to: URL(string: "https://unlisted.example/page")!))
        #expect(!context.hasAccessToPrivateData)
    }

    @Test func sitesAndClickModesContinueWithholdingOtherOptionalGrants() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let context = try await fixture.load()
        let allowed = URL(string: "https://allowed.example/page")!
        let other = URL(string: "https://other.example/page")!
        let required = URL(string: "https://required.example/page")!
        let otherPattern = try #require(try? WKWebExtension.MatchPattern(string: "*://other.example/*"))
        fixture.owner.setAccess(fixture.id, .sites)
        fixture.owner.allow("allowed.example", for: fixture.id)
        fixture.owner.give(sites: [otherPattern], to: context)
        #expect(context.hasAccess(to: allowed))
        #expect(!context.hasAccess(to: other))
        #expect(!context.hasAccess(to: required))

        fixture.owner.setAccess(fixture.id, .click)
        fixture.owner.give(sites: [otherPattern], to: context)
        #expect(!context.hasAccess(to: allowed))
        #expect(!context.hasAccess(to: other))
        #expect(!context.hasAccess(to: required))
        #expect(!context.hasAccessToPrivateData)
    }
}
