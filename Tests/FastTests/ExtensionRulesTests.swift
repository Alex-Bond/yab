import AppKit
import Network
import Testing
import WebKit
@testable import Fast

/// An extension's declarativeNetRequest rules on a page from its first
/// request (ExtensionRules). WebKit hands a new page an extension's compiled
/// rules by a lookup on its shared rule list store, which waits behind any
/// compile there: AdBlock's takes 13-17 s, again for every change, and pages
/// opened meanwhile loaded their ads. And WebKit fails disabling the last
/// rule set while it has no compiled file to remove.
@MainActor
@Suite(.serialized)
struct ExtensionRulesTests {
    private static let id = "yabrulestestaaaaaaaaaaaaaaaaaaaa"

    /// A small ad blocker: one rule set blocking "/ad-banner.gif" images,
    /// and a worker, when given, that runs as it loads.
    private func blocker(enabled: Bool, worker: String? = nil) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let background = worker == nil ? "" : #","background":{"service_worker":"worker.js"}"#
        try """
        {"manifest_version":3,"name":"Rules test","version":"1.0","permissions":["declarativeNetRequest","nativeMessaging"],
         "host_permissions":["<all_urls>"]\(background),
         "declarative_net_request":{"rule_resources":[{"id":"ads","enabled":\(enabled),"path":"rules.json"}]}}
        """.write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try #"[{"id":1,"priority":1,"action":{"type":"block"},"condition":{"urlFilter":"/ad-banner.gif","resourceTypes":["image"]}}]"#
            .write(to: folder.appendingPathComponent("rules.json"), atomically: true, encoding: .utf8)
        if let worker { try worker.write(to: folder.appendingPathComponent("worker.js"), atomically: true, encoding: .utf8) }
        return folder
    }

    private struct Loaded {
        let controller: WKWebExtensionController
        let context: WKWebExtensionContext
        let storage: URL
        let folder: URL
        let answers: Answers
    }

    /// What the test extension's worker says, through native messaging.
    @MainActor
    final class Answers: NSObject, WKWebExtensionControllerDelegate {
        var said: [String] = []

        func webExtensionController(_ controller: WKWebExtensionController, sendMessage message: Any, toApplicationWithIdentifier applicationIdentifier: String?, for extensionContext: WKWebExtensionContext) async throws -> Any? {
            if let text = message as? String, text.hasPrefix("first") || text.hasPrefix("second") { said.append(text) }
            return "noted"
        }
    }

    private func load(enabled: Bool, prepared: Bool, worker: String? = nil, shim: Bool = false) async throws -> Loaded {
        let folder = try blocker(enabled: enabled, worker: worker)
        // With the extension shim, as Yab installs it.
        if shim { try ExtensionShims.prepare(folder, fresh: true) }
        let controller = WKWebExtensionController(configuration: .init(identifier: UUID()))
        let answers = Answers()
        controller.delegate = answers
        let context = WKWebExtensionContext(for: try await WKWebExtension(resourceBaseURL: folder))
        context.uniqueIdentifier = Self.id
        for permission in context.webExtension.requestedPermissions { context.setPermissionStatus(.grantedExplicitly, for: permission) }
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
        let root = try #require(controller.configuration.value(forKey: "_storageDirectoryPath") as? String)
        let storage = URL(fileURLWithPath: root).appendingPathComponent(Self.id, isDirectory: true)
        if prepared { ExtensionRules.prepare(context, storage: storage) }
        try controller.load(context)
        return Loaded(controller: controller, context: context, storage: storage, folder: folder, answers: answers)
    }

    private func unload(_ loaded: Loaded) {
        ExtensionRules.forget(Self.id)
        try? loaded.controller.unload(loaded.context)
        try? FileManager.default.removeItem(at: loaded.folder)
        try? FileManager.default.removeItem(at: loaded.storage.deletingLastPathComponent())
    }

    @Test(arguments: [false, true], ["declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback"])
    func followsRequestRulesWithRequiredOrOptionalPermission(optional: Bool, permission: String) async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rule-permission-\(UUID())")
        let storage = folder.appendingPathComponent("storage", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let controller = TestExtensions.controller()
        let id = "permission" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defer {
            ExtensionRules.forget(id, owner: controller)
            try? FileManager.default.removeItem(at: folder)
        }
        // No static sets: an extension can add all its rules dynamically.
        let key = optional ? "optional_permissions" : "permissions"
        let manifest: [String: Any] = ["manifest_version": 3, "name": "Rule permission", "version": "1.0",
                                       key: [permission]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: folder.appendingPathComponent("manifest.json"))
        let found = try await WKWebExtension(resourceBaseURL: folder)
        let declared = optional ? found.optionalPermissions : found.requestedPermissions
        try #require(declared.contains { $0.rawValue == permission })
        let context = WKWebExtensionContext(for: found)
        context.uniqueIdentifier = id
        let requestRules = permission != "declarativeNetRequestFeedback"
        #expect(ExtensionRules.uses(found) == requestRules)
        ExtensionRules.prepare(context, storage: storage, owner: controller)
        #expect(ExtensionRules.report(id).isEmpty == !requestRules)
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent(ExtensionRules.fileName).path) == requestRules)
        // Watching a possible grant does not hand over before rules compile.
        #expect(!ExtensionRules.holds(id))
        #expect(!ExtensionRules.ready(id))
    }

    @Test func placeholderNeverReplacesACompiledList() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rules-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        ExtensionRules.placeholder(in: folder)
        let file = folder.appendingPathComponent(ExtensionRules.fileName)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Empty reads as no list.
        #expect(ExtensionRules.stamp(file) == nil)
        try Data("compiled".utf8).write(to: file)
        let stamp = try #require(ExtensionRules.stamp(file))
        ExtensionRules.placeholder(in: folder)
        #expect(try Data(contentsOf: file) == Data("compiled".utf8))
        #expect(ExtensionRules.stamp(file) == stamp)
        // A new compile is a new file renamed over the old one: a new stamp.
        let next = folder.appendingPathComponent("next")
        try Data("compiled again".utf8).write(to: next)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: next)
        #expect(ExtensionRules.stamp(file) != stamp)
    }

    @Test func snapshotSurvivesACompiledFileReplacement() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-rules-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("compiled.data")
        let copy = folder.appendingPathComponent("ContentRuleList-test")
        try Data("first rules".utf8).write(to: file)
        try ExtensionRules.snapshot(file, at: copy)
        let replacement = folder.appendingPathComponent("replacement.data")
        try Data("second rules".utf8).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: replacement)
        #expect(try Data(contentsOf: copy) == Data("first rules".utf8))
        #expect(try Data(contentsOf: file) == Data("second rules".utf8))
    }

    /// AdBlock's start, in small: its worker disables its rule set as it
    /// starts, before WebKit has compiled anything, then once more.
    private let disabling = """
        const disable = async () => {
          try { await chrome.declarativeNetRequest.updateEnabledRulesets({disableRulesetIds: ['ads']}); return 'ok'; }
          catch (e) { return String(e && e.message || e); }
        };
        (async () => {
          await chrome.runtime.sendNativeMessage('test', 'first ' + await disable());
          await new Promise(r => setTimeout(r, 1000));
          await chrome.runtime.sendNativeMessage('test', 'second ' + await disable());
        })();
        """

    private func said(_ loaded: Loaded) async throws -> [String] {
        for _ in 0..<200 where loaded.answers.said.count < 2 { try await Task.sleep(for: .milliseconds(50)) }
        return loaded.answers.said
    }

    @Test func disablingTheRuleSetAsItStartsSucceeds() async throws {
        let loaded = try await load(enabled: true, prepared: true, worker: disabling, shim: true)
        defer { unload(loaded) }
        #expect(try await said(loaded) == ["first ok", "second ok"])
    }

    @Test func webKitAloneOnDisablingAsItStarts() async throws {
        // What WebKit answers without the empty file, for the record (it
        // depends on whether its first compile has landed yet).
        let loaded = try await load(enabled: true, prepared: false, worker: disabling)
        defer { unload(loaded) }
        print("WebKit alone, disabling as it starts:", try await said(loaded))
    }

    /// The test page's two pictures, an ad and not, in a new view made the
    /// way a tab's is, while WebKit's shared rule list store is busy
    /// compiling a big list: which ones the server was asked for.
    private func pageWhileStoreIsBusy(_ loaded: Loaded, bridged: Bool, server: RulesServer) async throws -> Set<String> {
        let busy = "yab-rules-test-busy-\(UUID())"
        let rules = (0..<40_000).map { #"{"trigger":{"url-filter":"busy\#($0)[a-z]+x"},"action":{"type":"block"}}"# }
        let store = try #require(WKContentRuleListStore.default())
        var done = false
        store.compileContentRuleList(forIdentifier: busy, encodedContentRuleList: "[" + rules.joined(separator: ",") + "]") { _, _ in done = true }
        defer { store.removeContentRuleList(forIdentifier: busy) { _ in } }
        try await Task.sleep(for: .milliseconds(100))

        let configuration = WKWebViewConfiguration()
        configuration.webExtensionController = loaded.controller
        if bridged {
            ExtensionRules.give(configuration.userContentController, contexts: [Self.id: loaded.context], persistent: true)
        }
        server.reset()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        view.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/page")!))
        for _ in 0..<100 where view.isLoading || view.url == nil { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(500))
        let asked = server.paths
        #expect(done == false, "the store was still compiling while the page loaded")
        for _ in 0..<400 where !done { try await Task.sleep(for: .milliseconds(50)) }
        return asked
    }

    @Test func aNewPageHasTheRulesBeforeItLoads() async throws {
        let server = try RulesServer()
        defer { server.stop() }
        let loaded = try await load(enabled: true, prepared: true)
        defer { unload(loaded) }
        // WebKit compiles the rule set; the bridge reads what it wrote.
        for _ in 0..<200 where ExtensionRules.report(Self.id)["held"] as? Bool != true { try await Task.sleep(for: .milliseconds(50)) }
        #expect(ExtensionRules.report(Self.id)["held"] as? Bool == true)
        #expect(ExtensionRules.report(Self.id)["current"] as? Bool == true)

        let bridged = try await pageWhileStoreIsBusy(loaded, bridged: true, server: server)
        #expect(bridged.contains("/photo.gif"))
        #expect(!bridged.contains("/ad-banner.gif"))
        // WebKit alone: the page loads before its lookup gets a turn.
        let alone = try await pageWhileStoreIsBusy(loaded, bridged: false, server: server)
        #expect(alone.contains("/photo.gif"))
        #expect(alone.contains("/ad-banner.gif"))
    }

    @Test func keepsLastListWhileCompiledFileIsTemporarilyAbsent() async throws {
        let loaded = try await load(enabled: true, prepared: true)
        defer { unload(loaded) }
        for _ in 0..<200 where ExtensionRules.report(Self.id)["current"] as? Bool != true {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ExtensionRules.report(Self.id)["current"] as? Bool == true)

        let file = loaded.storage.appendingPathComponent(ExtensionRules.fileName)
        let staged = loaded.storage.appendingPathComponent("compiled-in-progress")
        defer { try? FileManager.default.removeItem(at: staged) }
        try FileManager.default.moveItem(at: file, to: staged)
        // The folder watcher sees the removal and restores an empty placeholder.
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(ExtensionRules.stamp(file) == nil)
        #expect(ExtensionRules.report(Self.id)["held"] as? Bool == true)
        #expect(ExtensionRules.report(Self.id)["current"] as? Bool == false)
    }

    // MARK: - rules put the way WebKit takes them

    /// A rule through WebKit's own declarativeNetRequest translator: the
    /// resource types of the content blocker rules it makes.
    private func translated(_ rule: [String: Any]) throws -> [[String]] {
        let translator = try #require(NSClassFromString("_WKWebExtensionDeclarativeNetRequestTranslator") as? NSObject.Type)
        typealias Translate = @convention(c) (AnyObject, Selector, NSDictionary, UnsafeMutablePointer<NSArray?>?) -> NSArray
        let selector = NSSelectorFromString("translateRules:errorStrings:")
        let translate = unsafeBitCast(translator.method(for: selector), to: Translate.self)
        var errors: NSArray?
        let out = translate(translator, selector, ["set": [rule]] as NSDictionary, &errors)
        return out.compactMap { (($0 as? [String: Any])?["trigger"] as? [String: Any])?["resource-type"] as? [String] }
    }

    private let easyList: [String: Any] = ["id": 1, "priority": 1, "action": ["type": "block"],
        "condition": ["urlFilter": "-ad-manager/", "resourceTypes": ["other", "csp_report", "script", "image", "object", "sub_frame",
                                                                     "websocket", "webbundle", "ping", "xmlhttprequest", "media", "font"]]]

    @Test func unknownResourceTypesNoLongerCostFramesAndFetches() throws {
        // WebKit alone: frames ("child-document") and fetches gone.
        let alone = try translated(easyList)
        #expect(alone.count == 1)
        #expect(!(alone.first ?? []).contains("child-document"))
        #expect(!(alone.first ?? []).contains("fetch"))
        // Mended: every type WebKit knows is kept.
        let mended = try #require(ExtensionRuleMends.mend(easyList, file: { _ in nil }))
        let condition = try #require(mended["condition"] as? [String: Any])
        #expect(condition["resourceTypes"] as? [String] == ["other", "script", "image", "sub_frame", "websocket", "ping", "xmlhttprequest", "media", "font"])
        let types = try #require(try translated(mended).first)
        #expect(Set(types) == ["other", "script", "image", "child-document", "websocket", "ping", "fetch", "media", "font"])
        // Stylesheets and top documents too.
        let sheet: [String: Any] = ["id": 2, "action": ["type": "block"], "condition": ["urlFilter": "/ad.css?", "resourceTypes": ["stylesheet", "object"]]]
        #expect(try translated(sheet).first?.contains("style-sheet") != true)
        #expect(try translated(try #require(ExtensionRuleMends.mend(sheet, file: { _ in nil }))).first == ["style-sheet"])
    }

    @Test func rulesWebKitTakesAsTheyAreAreLeftAlone() {
        let plain: [String: Any] = ["id": 3, "action": ["type": "block"], "condition": ["urlFilter": "/ads.js", "resourceTypes": ["script", "sub_frame"]]]
        #expect(ExtensionRuleMends.mend(plain, file: { _ in nil }) == nil)
        let none: [String: Any] = ["id": 4, "action": ["type": "block"], "condition": ["urlFilter": "/ads.js"]]
        #expect(ExtensionRuleMends.mend(none, file: { _ in nil }) == nil)
        // Only types WebKit doesn't know: WebKit refuses it, as before.
        let unknown: [String: Any] = ["id": 5, "action": ["type": "block"], "condition": ["urlFilter": "/x", "resourceTypes": ["object", "csp_report"]]]
        #expect(ExtensionRuleMends.mend(unknown, file: { _ in nil }) == nil)
    }

    @Test func aRedirectToDataGoesToAFileOfItsOwn() throws {
        let png = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAC0lEQVQI12NgQAcAABIAAe+JVKQAAAAASUVORK5CYII="
        #expect(ExtensionRuleMends.decode(png)?.suffix == "png")
        #expect(ExtensionRuleMends.decode(png)?.data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(ExtensionRuleMends.decode("data:text/plain,hello%20there")?.data == Data("hello there".utf8))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-mends-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("rules"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let rules: [[String: Any]] = [
            ["id": 1, "priority": 2000, "action": ["type": "redirect", "redirect": ["url": png]],
             "condition": ["urlFilter": "||example.com/*.png", "initiatorDomains": ["example.com"]]],
            easyList,
            ["id": 7, "action": ["type": "block"], "condition": ["urlFilter": "/ads.js"]],
        ]
        let rulesFile = folder.appendingPathComponent("rules/main.json")
        try JSONSerialization.data(withJSONObject: rules).write(to: rulesFile)
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Mends", "version": "1",
                                       "declarative_net_request": ["rule_resources": [["id": "main", "enabled": true, "path": "rules/main.json"]]]]
        ExtensionRuleMends.mendRuleSets(in: folder, manifest: &manifest)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: rulesFile)) as? [[String: Any]])
        #expect(written.count == 3)
        let redirect = try #require((written[0]["action"] as? [String: Any])?["redirect"] as? [String: Any])
        let path = try #require(redirect["extensionPath"] as? String)
        #expect(redirect["url"] == nil)
        #expect(path.hasPrefix("/yab-redirects/") && path.hasSuffix(".png"))
        #expect(try Data(contentsOf: folder.appendingPathComponent(String(path.dropFirst()))).prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(((written[1]["condition"] as? [String: Any])?["resourceTypes"] as? [String])?.contains("object") == false)
        #expect((written[2]["condition"] as? [String: Any])?["urlFilter"] as? String == "/ads.js")
        let accessible = try #require(manifest["web_accessible_resources"] as? [[String: Any]])
        #expect(accessible.contains { ($0["resources"] as? [String]) == ["yab-redirects/*"] && ($0["matches"] as? [String]) == ["<all_urls>"] })
        // WebKit's translator takes the redirect now.
        #expect(try translated(written[0]).count == 1)
        // Again: nothing more to do, nothing rewritten.
        let before = try FileManager.default.attributesOfItem(atPath: rulesFile.path)[.modificationDate] as? Date
        ExtensionRuleMends.mendRuleSets(in: folder, manifest: &manifest)
        #expect(try FileManager.default.attributesOfItem(atPath: rulesFile.path)[.modificationDate] as? Date == before)
        #expect((manifest["web_accessible_resources"] as? [Any])?.count == 1)
    }

    @Test func forgottenOnUnload() async throws {
        let loaded = try await load(enabled: true, prepared: true)
        for _ in 0..<200 where ExtensionRules.report(Self.id)["held"] as? Bool != true { try await Task.sleep(for: .milliseconds(50)) }
        unload(loaded)
        #expect(ExtensionRules.report(Self.id).isEmpty)
    }
}

/// An HTTP server on 127.0.0.1: the test page, a GIF for anything else, and
/// what was asked for.
private final class RulesServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var asked = Set<String>()
    private(set) var port: UInt16 = 0

    var paths: Set<String> { lock.lock(); defer { lock.unlock() }; return asked }
    func reset() { lock.lock(); asked = []; lock.unlock() }

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .global())
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let target = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let path = String(target.split(separator: "?").first ?? "")
            self?.lock.lock()
            self?.asked.insert(path)
            self?.lock.unlock()
            let body: Data
            let type: String
            if path == "/page" {
                body = Data("<!doctype html><body><img src=\"/ad-banner.gif\"><img src=\"/photo.gif\"></body>".utf8)
                type = "text/html"
            } else {
                body = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
                type = "image/gif"
            }
            var reply = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
            reply.append(body)
            connection.send(content: reply, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
