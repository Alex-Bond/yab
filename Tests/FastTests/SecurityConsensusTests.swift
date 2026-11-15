import AppKit
import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct SecurityConsensusTests {
    private func exception(at: Date? = nil) throws -> CertificateException {
        var fields: [String: Any] = ["host": "example.com", "port": 443, "chain": [Data([1, 2, 3]).base64EncodedString()]]
        if let at { fields["at"] = at.timeIntervalSinceReferenceDate }
        return try JSONDecoder().decode(CertificateException.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    private func withFile(_ check: (URL) throws -> Void) throws {
        let previous = CertificateExceptions.file
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("security-consensus-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            CertificateExceptions.file = previous
            CertificateExceptions.reload()
            try? FileManager.default.removeItem(at: folder)
        }
        let file = folder.appendingPathComponent("exceptions.json")
        CertificateExceptions.file = file
        CertificateExceptions.reload()
        try check(file)
    }

    @Test func anExpiredPersistentApprovalIsNotTrusted() throws {
        try withFile { file in
            let old = try exception(at: Date().addingTimeInterval(-91 * 24 * 3600))
            try JSONEncoder().encode(["default": [old]]).write(to: file)
            #expect(!CertificateExceptions.contains(try exception(), in: WKWebView()))
        }
    }

    @Test func legacyApprovalGetsAPersistedMigrationDate() throws {
        try withFile { file in
            let fields: [String: Any] = ["default": [["host": "example.com", "port": 443,
                                                       "chain": [Data([1, 2, 3]).base64EncodedString()]]]]
            try JSONSerialization.data(withJSONObject: fields).write(to: file)
            #expect(CertificateExceptions.contains(try exception(), in: WKWebView()))
            let first = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [[String: Any]]])
            let firstDate = try #require(first["default"]?.first?["at"] as? Double)
            CertificateExceptions.reload()
            #expect(CertificateExceptions.contains(try exception(), in: WKWebView()))
            let second = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: [[String: Any]]])
            #expect(second["default"]?.first?["at"] as? Double == firstDate)
        }
    }

    @Test func cachedApprovalsExpireForPersistentAndPrivateStores() throws {
        try withFile { _ in
            let now = Date()
            let approved = try exception(at: now)
            let persistent = WKWebView()
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let privateView = WKWebView(frame: .zero, configuration: config)
            for view in [persistent, privateView] {
                CertificateExceptions.allow(approved, in: view)
                #expect(CertificateExceptions.contains(approved, in: view, now: now))
                #expect(!CertificateExceptions.contains(approved, in: view, now: now.addingTimeInterval(7 * 24 * 3600)))
            }
        }
    }

    @Test func certificateDecisionsFollowTheStoreAcrossEngineSwitches() throws {
        try withFile { _ in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            let tab = Tab(shy: true, configuration: config)
            let otherConfig = WKWebViewConfiguration()
            otherConfig.websiteDataStore = .nonPersistent()
            let other = Tab(shy: true, configuration: otherConfig)
            defer { tab.close(); other.close() }
            let chromium = ChromiumPage(tab: tab), otherChromium = ChromiumPage(tab: other)
            let webKit = WKWebView(frame: .zero, configuration: config)
            let otherWebKit = WKWebView(frame: .zero, configuration: otherConfig)
            let approved = try exception()
            CertificateExceptions.allow(approved, in: chromium)
            #expect(CertificateExceptions.contains(approved, in: webKit))
            #expect(!CertificateExceptions.contains(approved, in: otherWebKit))
            #expect(!CertificateExceptions.contains(approved, in: otherChromium))
            CertificateExceptions.allow(approved, in: otherWebKit)
            #expect(CertificateExceptions.contains(approved, in: otherChromium))
            #expect(!CertificateExceptions.contains(approved, in: chromium, now: Date().addingTimeInterval(8 * 24 * 3600)))
            CertificateExceptions.forget(site: approved.host, in: config.websiteDataStore)
            #expect(!CertificateExceptions.contains(approved, in: chromium))
        }
    }

    @Test func migratingAChromiumCertificateDecisionKeepsItsOriginalExpiryAndCanBeForgotten() throws {
        try withFile { file in
            let config = WKWebViewConfiguration()
            config.websiteDataStore = Store.websites
            let tab = Tab(configuration: config)
            defer { tab.close() }
            let page = ChromiumPage(tab: tab)
            let approved = try exception(at: Date().addingTimeInterval(-6 * 24 * 3600))
            try JSONEncoder().encode(["chromium-" + page.profile: [approved]]).write(to: file)
            CertificateExceptions.reload()
            #expect(CertificateExceptions.contains(approved, in: page))
            let webKit = WKWebView(frame: .zero, configuration: config)
            #expect(CertificateExceptions.contains(approved, in: webKit))
            #expect(!CertificateExceptions.contains(approved, in: page, now: Date().addingTimeInterval(2 * 24 * 3600)))
            CertificateExceptions.forget(site: approved.host, in: config.websiteDataStore)
            #expect(!CertificateExceptions.contains(approved, in: page))
        }
    }

    @Test func clearingSharedDataForgetsLegacyMailAndPinCertificateDecisions() throws {
        try withFile { file in
            let approved = try exception()
            let sharedProfiles = [Space.firstID, Space.mailID, Space.pinsID]
            let unrelated = UUID()
            var grants = Dictionary(uniqueKeysWithValues: sharedProfiles.map { ("chromium-" + $0.uuidString, [approved]) })
            grants["chromium-" + unrelated.uuidString] = [approved]
            try JSONEncoder().encode(grants).write(to: file)
            CertificateExceptions.reload()
            CertificateExceptions.forget(site: approved.host, in: Store.websites)
            let remaining = try JSONDecoder().decode([String: [CertificateException]].self, from: Data(contentsOf: file))
            for profile in sharedProfiles {
                #expect(remaining["chromium-" + profile.uuidString] == nil)
            }
            #expect(remaining["chromium-" + unrelated.uuidString] == [approved])
        }
    }

    @Test func localAndPublicExceptionsUseDifferentLifetimes() {
        let now = Date()
        for (host, days) in [("example.com", 7), ("router.local", 30), ("192.168.1.1", 30), ("::1", 30)] {
            let approved = CertificateException(host: host, port: 443, chain: [Data([1])], at: now)
            #expect(!approved.expired(at: now.addingTimeInterval(Double(days * 24 * 3600 - 1))))
            #expect(approved.expired(at: now.addingTimeInterval(Double(days * 24 * 3600))))
        }
    }

    @Test func profilePermissionsDoNotFollowSymlinks() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("security-permissions-\(UUID())")
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: root) }
        let profile = root.appendingPathComponent("profile")
        try files.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let session = profile.appendingPathComponent("session.json")
        let outside = root.appendingPathComponent("outside.json")
        try Data().write(to: session)
        try Data().write(to: outside)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: session.path)
        try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outside.path)
        try files.createSymbolicLink(at: profile.appendingPathComponent("history.json"), withDestinationURL: outside)
        Store.harden(at: profile)
        #expect((try files.attributesOfItem(atPath: profile.path)[.posixPermissions] as? Int) == 0o700)
        #expect((try files.attributesOfItem(atPath: session.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try files.attributesOfItem(atPath: outside.path)[.posixPermissions] as? Int) == 0o644)
    }

    @Test(arguments: ["", "opener", "noopener"])
    func webKitOpenerPolicy(rel: String) async throws {
        _ = NSApplication.shared
        let source = try LocalNetworkFixture(), target = try LocalNetworkFixture()
        defer { source.stop(); target.stop() }
        target.route("/child", .init("<!doctype html><title>child</title><p id='ready'>ready</p>"))
        let browser = Browser(windowID: UUID())
        defer {
            for tab in browser.tabs { tab.built?.stopLoading(); tab.close() }
            browser.letGo()
            browser.dozing?.invalidate()
            browser.stuck.timer?.invalidate()
            browser.pressure?.cancel()
        }
        // Native related-view/opener fixture; ordinary tabs keep the selected engine.
        let parent = Tab(bench: true, factory: .webKitOnly)
        browser.prepare(parent)
        browser.lay(browser.tabs + [parent])
        parent.go(to: URL(string: "about:blank")!)
        requireNativeWebKitFixture(parent, "SecurityConsensusTests").loadHTMLString("<!doctype html><a id='link' href='\(target.root)/child' target='_blank' rel='\(rel)'>open</a>", baseURL: URL(string: source.root + "/parent"))
        try await until { (try? await requireNativeWebKitFixture(parent, "SecurityConsensusTests").evaluateJavaScript("!!document.getElementById('link')")) as? Bool == true }
        _ = try await requireNativeWebKitFixture(parent, "SecurityConsensusTests").evaluateJavaScript("document.getElementById('link').click()")
        try await until { browser.tabs.count == 2 }
        let child = try #require(browser.tabs.first { $0 !== parent })
        try await until { (try? await requireNativeWebKitFixture(child, "SecurityConsensusTests").evaluateJavaScript("!!document.getElementById('ready')")) as? Bool == true }
        let hasOpener = try await requireNativeWebKitFixture(child, "SecurityConsensusTests").evaluateJavaScript("window.opener !== null") as? Bool
        #expect(hasOpener == (rel == "opener"), "WebKit must sever implicit openers and honor explicit rel=opener")
    }

    private func until(_ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(Bool(false), "Timed out waiting for fixture")
    }
}
