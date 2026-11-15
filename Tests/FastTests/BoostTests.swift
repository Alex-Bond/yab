import Foundation
import Testing
@testable import Fast

struct BoostTests {
    static func files(css: String = ".shorts { display:none !important; }") -> [String: String] {
        ["manifest.json": #"{"manifest_version":3,"name":"Calm feed","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"css":["style.css"]}]}"#,
         "style.css": css,
         "BOOST.md": "---\nname: Calm feed\nsites: example.com\nchecks:\n  - on /: none of .shorts\n  - on /: some of main\n---\n\nHide Shorts."]
    }
    @Test func toolExamplesRejectUndeclaredCallsAndBadArguments() throws {
        let tool = BoostPlugin.Tool(name: "find", description: "Find items", parameters: ["count": "integer"], acts: nil)
        let good = "- ask: Find three items\n  tool: find\n  args: {\"count\":3}"
        #expect(try BoostExample.read(good, tools: [tool]).first?.tool == "find")
        for source in [good.replacingOccurrences(of: "tool: find", with: "tool: delete"),
                       good.replacingOccurrences(of: "3}", with: "true}"), good + "\n  tool: find",
                       "- ask: Find items\n  tool: find\n  args: &alias {}"] {
            #expect(throws: Error.self) { try BoostExample.read(source, tools: [tool]) }
        }
    }
    @Test func completedPressRetainsItsResolvedControlLabel() {
        let page = ChatItem.Page(title: "Fixture", host: "example.com")
        var items = [ChatItem(id: "1", kind: .tool, name: "press", detail: "“New issue”", page: page)]
        items.put(ChatItem(id: "1", kind: .tool, name: "press", detail: "tab:abcd", state: .done))
        #expect(items[0].detail == "“New issue”")
        #expect(items[0].page == page)
        #expect(items[0].state == .done)
    }
    @Test func learningRequiresMatchingSuccessfulClicksOnOneSite() {
        let page = ChatItem.Page(title: "Fixture", host: "example.com")
        let steps = [ChatItem(id: "1", kind: .tool, name: "press", detail: "Issues", state: .done, page: page),
                     ChatItem(id: "2", kind: .tool, name: "press", detail: "New issue", state: .done, page: page),
                     ChatItem(id: "3", kind: .message, text: "Done", state: .done)]
        #expect(BoostLearning.pattern(steps)?.site == "example.com")
        #expect(BoostLearning.pattern(Array(steps.prefix(2))) == nil)
        var failed = steps; failed[1].state = .failed
        #expect(BoostLearning.pattern(failed) == nil)
        var other = steps; other[1].page?.host = "elsewhere.com"
        #expect(BoostLearning.pattern(other) == nil)
        var raw = steps; raw[0].detail = "tab:12"
        #expect(BoostLearning.pattern(raw) == nil)
    }
    @Test func lookPackageHasNoScriptPrivileges() throws {
        let package = try BoostPackage.read(id: "calm-feed", files: Self.files(), sites: ["example.com"])
        #expect(package.rung == .look)
        #expect(package.checks.count == 2)
        #expect(package.matches(URL(string: "https://example.com/path")!))
        #expect(!package.matches(URL(string: "https://example.com.evil.test/path")!))
        #expect(!package.matches(URL(string: "http://example.com/path")!))
        #expect(!package.matches(URL(string: "https://sub.example.com/path")!))
    }
    @Test func pageRungIsInferred() throws {
        var files = Self.files()
        files["manifest.json"] = #"{"manifest_version":3,"name":"Copy button","version":"1","content_scripts":[{"matches":["https://example.com/*"],"js":["page.js"]}]}"#
        files["page.js"] = "document.body.dataset.boost = 'yes';"
        #expect(try BoostPackage.read(id: "copy", files: files, sites: ["example.com"]).rung == .page)
    }
    @Test func pathsCannotEscapeThePackage() {
        for path in ["../escape", "/tmp/file", "a/../b", "a//b", "a/./b", ".git/config", "a\\b", "a:b", "a\0b"] {
            #expect(!BoostPackage.validPath(path))
            #expect(throws: Error.self) { try BoostPackage.merge([path: "x"], into: [:]) }
        }
        #expect(BoostPackage.validPath("page/style.css"))
        #expect(!BoostPackage.validPath(String(repeating: "deep/", count: 9) + "file.js"))
    }
    @Test func patchesKeepOmittedFilesAndRemoveNulls() throws {
        let files = try BoostPackage.merge(["style.css": "new", "old.js": NSNull()], into: ["style.css": "old", "old.js": "code", "BOOST.md": "intent"])
        #expect(files == ["style.css": "new", "BOOST.md": "intent"])
    }
    @Test func cssCannotLoadNetworkResources() {
        for css in ["a{background:url(https://evil.test)}", "@import 'https://evil.test/x';", "a{background:image-set('x' 1x)}", #"a{background:u\72l(x)}"#] {
            #expect(throws: Error.self) { try BoostPackage.read(id: "test", files: Self.files(css: css), sites: ["example.com"]) }
        }
    }
    @Test func additionalPermissionsAndSitesFailClosed() {
        for manifest in [
            #"{"manifest_version":3,"name":"X","version":"1","background":{"service_worker":"evil.js"},"content_scripts":[{"matches":["https://example.com/*"],"css":["style.css"]}]}"#,
            #"{"manifest_version":3,"name":"X","version":"1","content_scripts":[{"matches":["<all_urls>"],"css":["style.css"]}]}"#,
            #"{"manifest_version":3,"name":"X","version":"1","content_scripts":[{"matches":["https://elsewhere.com/*"],"css":["style.css"]}]}"#,
            #"{"manifest_version":3,"name":"X","version":"1","content_scripts":[{"matches":["https://example.com/*"],"css":["missing.css"]}]}"#,
            #"{"manifest_version":3,"name":"X","version":"1","content_scripts":[{"matches":["https://example.com/*"],"css":["style.css"],"all_frames":true}]}"#
        ] {
            var files = Self.files(); files["manifest.json"] = manifest
            #expect(throws: Error.self) { try BoostPackage.read(id: "test", files: files, sites: ["example.com"]) }
        }
    }
    @Test func checksAreTypedAndMalformedChecksFail() throws {
        #expect(try BoostCheck.parse("on /*: 4 per row in main").count == 4)
        let text = try BoostCheck.parse("on /issues/*: text Open in .status")
        #expect(text.words == "Open")
        #expect(text.path == "/issues/*")
        for line in ["on /: some of ", "on /: 0 per row in main", "on /: script arbitrary()", "none of .x"] {
            #expect(throws: Error.self) { try BoostCheck.parse(line) }
        }
    }
    @Test func savedVersionsSurviveReloadAndRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BoostLibrary(root: root)
        let first = try BoostPackage.read(id: "calm-feed", files: Self.files(), sites: ["example.com"])
        let record = try library.keep(first, author: "Claude", session: "a")
        #expect(try library.records().first == record)
        let loaded = try library.files(record.id)
        #expect(loaded == first.files, Comment(rawValue: "Loaded: " + BoostScript.json(loaded) + "; root: " + root.path))
        let second = try BoostPackage.read(id: "calm-feed", files: Self.files(css: "main { color: red; }"), sites: ["example.com"])
        _ = try library.keep(second, author: "Codex", session: "b")
        #expect(library.history(record.id).count == 2)
        #expect(try library.files(record.id)["style.css"] == second.css)
        _ = try library.keep(first, author: "You", session: "a")
        #expect(try library.files(record.id) == first.files)
        try library.delete(record.id)
        #expect(try library.records().isEmpty)
        #expect(library.history(record.id).count == 3)
    }
    @Test func symlinksAreNotImported() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-link-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("style.css"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: Error.self) { try BoostLibrary(root: root).read(root) }
    }
    @Test func tooLargePackagesAreRejectedBeforeWriting() {
        #expect(throws: Error.self) { try BoostPackage.merge(["large.css": String(repeating: "x", count: 512_001)], into: [:]) }
    }
    @Test func catalogPackagesAreValidated() throws {
        #expect(BoostCatalog.entries.count == 20)
        for entry in BoostCatalog.entries {
            let package = try BoostPackage.read(id: entry.id, files: entry.files, sites: [entry.site])
            #expect(package.rung == .look)
            #expect(package.matches(entry.url))
            #expect(!package.checks.isEmpty)
        }
    }
    @Test func sharedLookRevisionDetectsTampering() throws {
        let package = try BoostPackage.read(id: "calm-feed", files: Self.files(), sites: ["example.com"])
        let data = try BoostShare.export(package)
        let imported = try BoostShare.read(data)
        #expect(imported.files == package.files)
        #expect(imported.id.hasPrefix("shared-"))
        var raw = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var payload = raw["payload"] as! [String: Any]
        var files = payload["files"] as! [String: String]; files["style.css"] = "body{display:none}"
        payload["files"] = files; raw["payload"] = payload
        let changed = try JSONSerialization.data(withJSONObject: raw)
        #expect(throws: Error.self) { try BoostShare.read(changed) }
    }
    @Test func executableChecksCannotMasqueradeAsLook() throws {
        var files = Self.files(); files["checks.js"] = "boost.check('ok',()=>true)"
        files["BOOST.md"] = "---\nchecks:\n  - on /*: script ok\n---\nHide Shorts."
        let package = try BoostPackage.read(id: "checked", files: files, sites: ["example.com"])
        #expect(package.rung == .page)
        #expect(throws: Error.self) { try BoostShare.export(package) }
        files.removeValue(forKey: "checks.js")
        #expect(throws: Error.self) { try BoostPackage.read(id: "checked", files: files, sites: ["example.com"]) }
    }
    @Test func pluginCapabilitiesFailClosed() throws {
        for metadata: [String: Any] in [["permissions": ["yab:secrets"]], ["permissions": "yab:ask"], ["tools": "invalid"], ["daily_limit": true], ["daily_limit": 1.5], ["unknown": true], ["service":"service.js","every":"1m"]] {
            #expect(throws: Error.self) { try BoostPlugin.parse(metadata, files: ["service.js":"function tick(){}"] ) }
        }
        let plugin = try BoostPlugin.parse(["tools": ["find": ["description": "Find issues", "params": ["count": "integer", "query": "string?"]]]], files: ["tools.js": "export const find=()=>[]"])
        try plugin.tools[0].validate(["count": 2])
        for args: [String: Any] in [["count": true], ["count": 1.5], ["count":2,"unknown":"x"], [:]] {
            #expect(throws: Error.self) { try plugin.tools[0].validate(args) }
        }
        #expect(throws: Error.self) { try BoostPlugin.parse(["tools": ["find": ["description":"Find", "params":["q":"str?ing"]]]], files:["tools.js":""]) }
    }
    @Test func contributionsCannotEscapeDeclaredSites() throws {
        let valid = #"{"actions":[{"id":"inbox","name":"Inbox","url":"https://example.com/inbox"}]}"#
        #expect(try BoostContributions.read(["commands.json":valid], sites:["example.com"]).actions.count == 1)
        #expect(throws: Error.self) { try BoostContributions.read(["commands.json": valid.replacingOccurrences(of:"example.com",with:"evil.test")], sites:["example.com"]) }
        #expect(throws: Error.self) { try BoostContributions.read(["commands.json": #"{"commands":[{"id":"leak","name":"Leak","prompt":"{memory}"}]}"#], sites:["example.com"]) }
        #expect(throws: Error.self) { try BoostContributions.read(["commands.json": #"{"routines":[{"id":"watch","name":"Watch","prompt":"Watch","when":"nonsense"}]}"#], sites:["example.com"]) }
    }

    @Test func structuredModelOutputIsValidated() throws {
        let schema: [String: Any] = ["type":"object", "properties":["count":["type":"integer"],"kind":["type":"string","enum":["a","b"]]], "required":["count","kind"], "additionalProperties":false]
        try BoostJSON.checkSchema(schema)
        _ = try BoostJSON.answer(#"{"count":2,"kind":"a"}"#, schema:schema)
        for text in [#"{"count":true,"kind":"a"}"#, #"{"count":2,"kind":"c"}"#, #"{"count":2}"#, #"{"count":2,"kind":"a","extra":1}"#, "Here is the JSON:"] {
            #expect(throws: Error.self) { try BoostJSON.answer(text, schema:schema) }
        }
        #expect(throws: Error.self) { try BoostJSON.checkSchema(["$ref":"https://example.com/schema"]) }
    }
    @Test func cliAcceptsTypedFlagsAndJson() throws {
        let schema = BoostPlugin.Tool(name:"create_issue",description:"Create",parameters:["title":"string","count":"integer","open":"boolean?"],acts:"post").schema
        let flags = try BoostCLI.parse(["--title","Literal $text", "--count","2","--open","--json"],schema:schema)
        #expect(flags["title"] as? String == "Literal $text")
        #expect(flags["count"] as? Int == 2)
        #expect(flags["open"] as? Bool == true)
        #expect(throws: Error.self) { try BoostCLI.parse(["--unknown","x"],schema:schema) }
        #expect(throws: Error.self) { try BoostCLI.parse(["--title","x","--title","y"],schema:schema) }
    }
    @Test func unreadableExecutablePackagesAreRejected() {
        for code in ["eval('1')", "new Function('1')", "import('https://example.com')", "// hidden \u{202E}", String(repeating:"x",count:2001)] {
            var files=Self.files();files["checks.js"]=code
            #expect(throws: Error.self) { try BoostPackage.read(id:"test",files:files,sites:["example.com"]) }
        }
    }

    @Test func keptFilesAreBoundToTheApprovedRevision() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-digest-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BoostLibrary(root: root)
        let package = try BoostPackage.read(id: "calm", files: Self.files(), sites: ["example.com"])
        let record = try library.keep(package, author: "You", session: "fixture")
        #expect(record.digest != nil)
        try "body{display:none}".write(to: library.folder("calm").appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        #expect(throws: Error.self) { try library.files("calm") }
        #expect(try library.records().first?.revision == record.revision)
    }

    @Test func onlyExplicitEverySiteConversionBroadensScope() throws {
        let local = try BoostPackage.read(id:"calm",files:Self.files(),sites:["example.com"])
        #expect(!local.matches(URL(string:"https://elsewhere.test/")!))
        let broad = try local.applyingEverywhere()
        #expect(broad.rung == .app)
        #expect(broad.matches(URL(string:"https://elsewhere.test/")!))
        #expect(!broad.matches(URL(string:"yab://store")!))
        #expect(throws: Error.self) { try BoostPackage.read(id:"calm",files:broad.files,sites:["example.com"]) }
        #expect(throws: Error.self) { try BoostShare.export(broad) }
    }


    static func pageFiles(hosts: [String]? = nil, permissions: [String]? = nil, siteActions: [String]? = nil, code: String = "document.body.dataset.boost = 'yes';") -> [String: String] {
        var yab: [String: Any] = [:]
        if let hosts { yab["hosts"] = hosts }
        if let permissions { yab["permissions"] = permissions }
        if let siteActions { yab["site_actions"] = siteActions }
        var manifest: [String: Any] = ["manifest_version": 3, "name": "Sponsor skip", "version": "1",
                                       "content_scripts": [["matches": ["https://example.com/*"], "js": ["page.js"]]]]
        if !yab.isEmpty { manifest["yab"] = yab }
        return ["manifest.json": BoostScript.json(manifest), "page.js": code,
                "BOOST.md": "---\nname: Sponsor skip\nchecks:\n  - on /: some of main\n---\n\nSkip sponsored segments."]
    }

    @Test func permissionsAreSaidInWords() throws {
        let both = try BoostPackage.read(id: "watch", files: Self.pageFiles(permissions: ["yab:task", "yab:ask"]), sites: ["example.com"])
        #expect(both.permission == "Run code on example.com. It can read and change these pages. Can start agent tasks and use your AI plan. Up to 20 AI calls a day.")
        let three = try BoostPackage.read(id: "watch", files: Self.pageFiles(permissions: ["yab:calendar", "yab:live", "yab:notify"]), sites: ["example.com"])
        #expect(three.permission.hasSuffix(" Can read your next meeting, add live folders and show notifications."))
        #expect(!three.permission.contains("AI calls"))
        // A service alone never runs inside the site's pages, and says so.
        let watch = try BoostPackage.read(id: "watch", files: [
            "manifest.json": BoostScript.json(["manifest_version": 3, "name": "Release watch", "version": "1",
                                               "yab": ["service": "service.js", "every": "60m"]]),
            "service.js": "async function tick() { return {} }",
            "BOOST.md": "---\nname: Release watch\n---\n\nWatch releases."], sites: ["example.com"])
        #expect(watch.permission == "Run code for example.com, outside its pages. Checks public data every 60 minutes.")
        // Every permission a plugin may ask for has its words.
        #expect(Set(BoostPackage.rights.keys) == BoostPlugin.permissions)
    }

    @Test func siteActionsAreExactLocalGrantsAndUpdatesAskAgain() throws {
        let plain = try BoostPackage.read(id: "buttons", files: Self.pageFiles(), sites: ["example.com"])
        let clicks = try BoostPackage.read(id: "buttons", files: Self.pageFiles(siteActions: ["clicks"]), sites: ["example.com"])
        #expect(clicks.plugin.siteActions == ["clicks"])
        #expect(clicks.rung == .page)
        #expect(clicks.permission.hasSuffix(" Presses buttons on example.com."))
        #expect(clicks.widens(plain))
        #expect(!plain.widens(clicks))
        #expect(!clicks.canApplyEverywhere)
        #expect(throws: Error.self) { try clicks.applyingEverywhere() }
        for value: Any in ["clicks", ["clicks", "clicks"], ["navigation"], ["fetch"], [true]] {
            #expect(throws: Error.self) { try BoostPlugin.parse(["site_actions": value], files: [:]) }
        }
        var files = Self.pageFiles(siteActions: ["clicks"])
        var all = try JSONSerialization.jsonObject(with: Data(files["manifest.json"]!.utf8)) as! [String: Any]
        all["content_scripts"] = [["matches": ["<all_urls>"], "js": ["page.js"]]]
        files["manifest.json"] = BoostScript.json(all)
        #expect(throws: Error.self) { try BoostPackage.read(id: "buttons", files: files, sites: ["<all_urls>"]) }
        var css = Self.files()
        var manifest = try JSONSerialization.jsonObject(with: Data(css["manifest.json"]!.utf8)) as! [String: Any]
        manifest["yab"] = ["site_actions": ["clicks"]]
        css["manifest.json"] = BoostScript.json(manifest)
        #expect(throws: Error.self) { try BoostPackage.read(id: "buttons", files: css, sites: ["example.com"]) }
    }

    @Test func quietTrialSaysWhereItWasChecked() {
        func url(_ s: String) -> URL { URL(string: s)! }
        #expect(Boosts.checked([url("https://www.youtube.com/"), url("https://www.youtube.com/results?search_query=cats"),
                                url("https://www.youtube.com/watch?v=1")]) == "Checked on Home, search and a video.")
        #expect(Boosts.checked([url("https://example.com/")]) == "Checked on Home.")
        #expect(Boosts.checked([url("https://example.com/feed")]) == nil)
        #expect(Boosts.checked([url("https://example.com/"), url("https://example.com/feed")]) == "Checked on Home and one more page.")
        #expect(Boosts.headline("## Price dropped\n\nto $79") == "Price dropped")
    }

    @Test func hostsAreExactHTTPSNamesAndAtMostFour() throws {
        let plugin = try BoostPlugin.parse(["hosts": ["sponsor.ajay.app", "api.example.com"]], files: [:])
        #expect(plugin.hosts == ["sponsor.ajay.app", "api.example.com"])
        for hosts: Any in [["a.com", "b.com", "c.com", "d.com", "e.com"], ["API.example.com"], ["https://api.example.com"],
                           ["*.example.com"], ["api.example.com:443"], ["127.0.0.1"], ["localhost"], ["a.com", "a.com"],
                           ["api.example.com/path"], "api.example.com", [""]] {
            #expect(throws: Error.self) { try BoostPlugin.parse(["hosts": hosts], files: [:]) }
        }
    }

    @Test func hostsAreSaidAndMakeCodeAtLeastPage() throws {
        let package = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["sponsor.ajay.app", "api.example.com"]), sites: ["example.com"])
        #expect(package.rung == .page)
        #expect(package.permission == "Run code on example.com. It can read and change these pages. Talks to sponsor.ajay.app, api.example.com.")
        // A stylesheet that names hosts is no longer a Look: it has a reach to explain.
        var look = Self.files()
        look["manifest.json"] = #"{"manifest_version":3,"name":"Calm feed","version":"1.0","yab":{"hosts":["api.example.com"]},"content_scripts":[{"matches":["https://example.com/*"],"css":["style.css"]}]}"#
        let styled = try BoostPackage.read(id: "calm", files: look, sites: ["example.com"])
        #expect(styled.rung == .page)
        #expect(styled.permission.hasSuffix(" Talks to api.example.com."))
        #expect(throws: Error.self) { try BoostShare.export(styled) }
        // The page script's fetch wrapper knows them.
        #expect(BoostScript.source(package).contains(#"const hosts = ["sponsor.ajay.app","api.example.com"]"#))
    }

    @Test func updatesThatAskForMoreAreWider() throws {
        let kept = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com"]), sites: ["example.com"])
        let sameRights = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com"], code: "document.title = 'new';"), sites: ["example.com"])
        let fewer = try BoostPackage.read(id: "skip", files: Self.pageFiles(), sites: ["example.com"])
        let moreHosts = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com", "other.example.org"]), sites: ["example.com"])
        let morePermissions = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com"], permissions: ["yab:notify"]), sites: ["example.com"])
        let look = try BoostPackage.read(id: "skip", files: Self.files(), sites: ["example.com"])
        #expect(!sameRights.widens(kept))
        #expect(!fewer.widens(kept))
        #expect(moreHosts.widens(kept))
        #expect(morePermissions.widens(kept))
        #expect(kept.widens(look))
        #expect(!look.widens(look))
        let otherSite = try BoostPackage.read(id: "skip", files: Self.files().mapValues { $0.replacingOccurrences(of: "example.com", with: "example.org") }, sites: ["example.org"])
        #expect(otherSite.widens(look))
    }

    // Safe mode is ⌥ held as Yab opened, not when boosts are first needed.
    @MainActor @Test func safeModeIsWhatLaunchSaw() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-safe-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); Boosts.optionAtLaunch = nil }
        Boosts.optionAtLaunch = true
        #expect(Boosts(root: root).safeMode)
        Boosts.optionAtLaunch = false
        #expect(!Boosts(root: root).safeMode)
    }

    @MainActor @Test func aWiderUpdateTurnsTheKeptPluginOffAndKeepsItsFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-update-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com"]), sites: ["example.com"])
        _ = try BoostLibrary(root: root).keep(kept, author: "Store", session: "store")
        let boosts = Boosts(root: root, safeMode: false)
        let wider = try BoostPackage.read(id: "shared-0123456789abcdef", files: Self.pageFiles(hosts: ["api.example.com", "other.example.org"]), sites: ["example.com"])
        #expect(try await boosts.update("skip", to: wider) == .held)
        #expect(boosts.records.first?.enabled == false)
        #expect(try boosts.library.files("skip") == kept.files)
        await boosts.setEnabled("skip", true)
        let same = try BoostPackage.read(id: "skip", files: Self.pageFiles(hosts: ["api.example.com"], code: "document.title = 'new';"), sites: ["example.com"])
        #expect(try await boosts.update("skip", to: same) == .applied)
        #expect(boosts.records.first?.enabled == true)
        #expect(try boosts.library.files("skip")["page.js"] == "document.title = 'new';")
    }


    @MainActor @Test func codeFromAnotherMacWaitsOffUntilTurnedOnHere() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("boost-synced-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let boosts = Boosts(root: root, safeMode: false)
        let code = try BoostPackage.read(id: "skip", files: Self.pageFiles(), sites: ["example.com"])
        let look = try BoostPackage.read(id: "calm-feed", files: Self.files(), sites: ["example.com"])
        try boosts.keepSynced(code, author: "You", enabled: true, runsOn: "a", synced: true)
        try boosts.keepSynced(look, author: "You", enabled: true, runsOn: "a", synced: true)
        func record(_ id: String) -> BoostRecord? { boosts.records.first { $0.id == id } }
        #expect(record("skip")?.enabled == false && record("skip")?.waits == true && record("skip")?.runsOn == "a")
        #expect(!boosts.isEnabled("skip"))
        #expect(record("calm-feed")?.enabled == true && record("calm-feed")?.waits == nil)
        // Kept so: a relaunch reads it waiting.
        #expect(try boosts.library.records().first { $0.id == "skip" }?.waits == true)
        // The account saying on doesn't turn it on; who ticks it still moves.
        boosts.applySynced("skip", enabled: true, runsOn: "b")
        #expect(record("skip")?.enabled == false && record("skip")?.waits == true && record("skip")?.runsOn == "b")
        // Off here is no yes; on here is, and from then on the account's say goes.
        await boosts.setEnabled("skip", false)
        #expect(record("skip")?.waits == true)
        await boosts.setEnabled("skip", true)
        #expect(record("skip")?.enabled == true && record("skip")?.waits == nil && boosts.isEnabled("skip"))
        boosts.applySynced("skip", enabled: false, runsOn: "b")
        #expect(record("skip")?.enabled == false)
        boosts.applySynced("skip", enabled: true, runsOn: "b")
        #expect(record("skip")?.enabled == true)
        // A look follows the account as it always has.
        boosts.applySynced("calm-feed", enabled: false, runsOn: "a")
        #expect(record("calm-feed")?.enabled == false)
        // Kept not from sync (a test run, an import): as told.
        let other = try BoostPackage.read(id: "other", files: Self.pageFiles(), sites: ["example.com"])
        try boosts.keepSynced(other, author: "Arc", enabled: true)
        #expect(record("other")?.enabled == true && record("other")?.waits == nil)
    }

    @MainActor @Test func pageEditsDuringATickSurviveItsSave() throws {
        let id = "storage-" + UUID().uuidString.prefix(8).lowercased()
        defer { Store.settings.removeObject(forKey: BoostStorage.key(id)) }
        try BoostStorage.set(id, ["count": 1, "note": "old", "gone": true])
        let started = try JSONSerialization.jsonObject(with: Data(BoostStorage.begin(id).utf8)) as! [String: Any]
        #expect(started["count"] as? Int == 1)
        // The person edits while the tick runs; the tick then saves its copy.
        try BoostStorage.set(id, ["note": "mine", "gone": NSNull()])
        #expect(BoostStorage.get(id)["note"] as? String == "mine")
        var tick = started; tick["count"] = 2
        BoostStorage.end(id, storage: tick)
        let now = BoostStorage.get(id)
        #expect(now["count"] as? Int == 2)
        #expect(now["note"] as? String == "mine")
        #expect(now["gone"] == nil)
        // A failed tick leaves the saved state; no tick, no edits kept aside.
        _ = BoostStorage.begin(id); BoostStorage.end(id, storage: nil)
        #expect(BoostStorage.get(id)["count"] as? Int == 2)
        #expect(throws: Error.self) { try BoostStorage.set(id, ["big": String(repeating: "x", count: 64_001)]) }
        #expect(throws: Error.self) { try BoostStorage.set(id, ["": 1]) }
    }

    @Test func serviceFetchStaysOnThePluginsHosts() throws {
        let hosts: Set<String> = ["www.amazon.com", "api.example.com"]
        let get = try BoostServiceFetch.request(["url": "https://www.amazon.com/dp/B0", "method": "get", "headers": ["Accept": "text/html"]], hosts: hosts)
        #expect(get.httpMethod == "GET")
        #expect(get.httpShouldHandleCookies == false)
        let post = try BoostServiceFetch.request(["url": "https://api.example.com/v1", "method": "POST", "body": "{}", "headers": ["Content-Type": "application/json"]], hosts: hosts)
        #expect(post.httpBody == Data("{}".utf8))
        for body: [String: Any] in [["url": "http://www.amazon.com/"], ["url": "https://evil.test/"], ["url": "https://www.amazon.com:8443/"],
                                    ["url": "https://user@www.amazon.com/"], ["url": "https://www.amazon.com/", "method": "PUT"],
                                    ["url": "https://www.amazon.com/", "body": "x"], ["url": "https://www.amazon.com/", "headers": ["Cookie": "a=b"]],
                                    ["url": "https://amazon.com/"], ["url": "not a url"]] {
            #expect(throws: Error.self) { try BoostServiceFetch.request(body, hosts: hosts) }
        }
    }

}
