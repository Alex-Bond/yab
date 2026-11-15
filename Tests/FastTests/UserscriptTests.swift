import Foundation
import Testing
@testable import Fast

/// Reading `.user.js` headers, the Keep card's sentence and what an update
/// asks for (docs/userscripts.md).
struct UserscriptTests {
    static func script(_ header: [String], body: String = "") -> String {
        "// ==UserScript==\n" + header.map { "// " + $0 }.joined(separator: "\n") + "\n// ==/UserScript==\n" + body
    }

    /// Return YouTube Dislike 3.2.0's header, and the line that calls its API.
    static let dislike = script([
        "@name         Return YouTube Dislike", "@namespace    https://www.returnyoutubedislike.com/", "@version      3.2.0",
        "@match        *://*.youtube.com/*", "@exclude      *://music.youtube.com/*", "@exclude      *://*.music.youtube.com/*",
        "@grant        GM.getValue", "@grant        GM.setValue", "@grant        GM_getValue", "@grant        GM_setValue", "@grant        GM_addStyle",
        "@run-at       document-end",
        "@downloadURL https://update.greasyfork.org/scripts/436115/Return%20YouTube%20Dislike.user.js",
        "@updateURL https://update.greasyfork.org/scripts/436115/Return%20YouTube%20Dislike.meta.js",
    ], body: """
    // See https://github.com/Anarios/return-youtube-dislike for help.
    const homepage = "https://www.returnyoutubedislike.com/";
    const API_BASE_URL = "https://returnyoutubedislikeapi.com";
    fetch(`${API_BASE_URL}/votes?videoId=1`);
    GM_setValue("x", 1);
    """)

    @Test func headerIsRead() throws {
        let script = try Userscript.read(Self.dislike)
        #expect(script.name == "Return YouTube Dislike")
        #expect(script.version == "3.2.0")
        #expect(script.matches == ["*://*.youtube.com/*"])
        #expect(script.excludes.count == 2)
        #expect(script.runAt == "document-end")
        #expect(script.updateURL?.absoluteString.hasSuffix(".meta.js") == true)
        #expect(!script.inPage)
        #expect(throws: Error.self) { try Userscript.read("const x = 1;") }
        #expect(Userscript.looks(Self.dislike))
        #expect(!Userscript.looks("function f() {}"))
    }

    @Test func sentenceSaysSitesHostsAndSettings() throws {
        let script = try Userscript.read(Self.dislike)
        #expect(script.sites == ["youtube.com"])
        #expect(script.hosts == ["returnyoutubedislikeapi.com"])
        #expect(script.permission == "Run code on youtube.com, not music.youtube.com. Talks to returnyoutubedislikeapi.com. Keeps its own settings.")
    }

    @Test func sentenceForEverySiteAnyHostAndSignIn() throws {
        let everywhere = try Userscript.read(Self.script(["@name A", "@match *://*/*", "@grant GM_addStyle"]))
        #expect(everywhere.permission == "Read and change every site you visit.")
        let any = try Userscript.read(Self.script(["@name B", "@match https://example.com/*", "@grant GM_xmlhttpRequest", "@connect *"]))
        #expect(any.permission == "Run code on example.com. Can talk to any site.")
        let signed = try Userscript.read(Self.script(["@name C", "@match https://example.com/*", "@grant GM_xmlhttpRequest", "@connect api.example.org"]))
        #expect(signed.permission == "Run code on example.com. Talks to api.example.org with your sign-in.")
        let page = try Userscript.read(Self.script(["@name D", "@match https://example.com/*", "@grant none"]))
        #expect(page.inPage)
        #expect(page.permission == "Run code on example.com. Runs inside the page, where it can see what you type.")
        let many = try Userscript.read(Self.script(["@name E", "@match *://a.com/*", "@match *://b.com/*", "@match *://c.com/*", "@match *://d.com/*", "@grant GM_addStyle"]))
        #expect(many.permission == "Run code on a.com, b.com and 2 other sites.")
    }

    @Test func requiresAreNamed() {
        #expect(Userscript.describe(require: "https://cdnjs.cloudflare.com/ajax/libs/tocbot/4.18.2/tocbot.min.js") == "tocbot 4.18.2 from cdnjs")
        #expect(Userscript.describe(require: "https://cdn.jsdelivr.net/npm/cash-dom@8.1.0/dist/cash.min.js") == "cash-dom 8.1.0 from jsDelivr")
        #expect(Userscript.describe(require: "https://unpkg.com/dayjs@1.10.4/dayjs.min.js") == "dayjs 1.10.4 from unpkg")
        #expect(Userscript.describe(require: "https://code.jquery.com/jquery-3.7.1.min.js") == "jquery-3.7.1 from jquery.com")
    }

    @Test func patternsMatchAsTampermonkeyDoes() throws {
        let script = try Userscript.read(Self.dislike)
        #expect(script.matches(URL(string: "https://www.youtube.com/watch?v=1")!))
        #expect(script.matches(URL(string: "https://youtube.com/")!))
        #expect(!script.matches(URL(string: "https://music.youtube.com/")!))
        #expect(!script.matches(URL(string: "https://www.youtube.com.evil.test/")!))
        #expect(script.mayRun(on: "m.youtube.com"))
        #expect(!script.mayRun(on: "example.com"))
        let reddit = try Userscript.read(Self.script(["@name R", #"@include /https?:\/\/((www|pay|[a-z]{2})\.)?reddit\.com\/r\/[a-zA-Z0-9_-]+\/comments\/.*/"#]))
        #expect(reddit.sites == ["reddit.com"])
        #expect(reddit.matches(URL(string: "https://www.reddit.com/r/swift/comments/abc/title/")!))
        #expect(!reddit.matches(URL(string: "https://www.reddit.com/r/swift/")!))
        let local = try Userscript.read(Self.script(["@name L", "@match http://127.0.0.1/*"]))
        #expect(local.matches(URL(string: "http://127.0.0.1:8123/page.html")!))
        #expect(!local.matches(URL(string: "https://127.0.0.1:8123/")!))
        let glob = try Userscript.read(Self.script(["@name G", "@include https://news.ycombinator.com/*"]))
        #expect(glob.matches(URL(string: "https://news.ycombinator.com/item?id=1")!))
        #expect(Userscripts.firstPage(script)?.absoluteString == "https://youtube.com/")
    }

    @Test func updatesThatAskForMoreAreTold() throws {
        let kept = try Userscript.read(Self.dislike)
        let same = try Userscript.read(Self.dislike.replacingOccurrences(of: "3.2.0", with: "3.3.0"))
        #expect(same.more(than: kept).isEmpty)
        let host = try Userscript.read(Self.dislike.replacingOccurrences(of: "// @run-at", with: "// @connect      stats.returnyoutubedislike.com\n// @run-at"))
        #expect(host.more(than: kept) == ["Talks to stats.returnyoutubedislike.com with your sign-in"])
        let site = try Userscript.read(Self.dislike.replacingOccurrences(of: "// @run-at", with: "// @match        *://*.vimeo.com/*\n// @run-at"))
        #expect(site.more(than: kept) == ["Runs on vimeo.com"])
        let page = try Userscript.read(Self.dislike + "\nunsafeWindow.x = 1;\n")
        #expect(page.more(than: kept) == ["Runs inside the page, where it can see what you type"])
        var withLib = try Userscript.read(Self.dislike.replacingOccurrences(of: "// @run-at", with: "// @require https://unpkg.com/dayjs@1.10.4/dayjs.min.js\n// @run-at"))
        withLib.requires = [Userscript.File(name: "", url: "https://unpkg.com/dayjs@1.10.4/dayjs.min.js", sha256: "a", text: "")]
        #expect(withLib.more(than: kept) == ["Includes dayjs 1.10.4 from unpkg"])
        var changed = withLib
        changed.requires[0].sha256 = "b"
        #expect(changed.more(than: withLib) == ["Changes dayjs 1.10.4 from unpkg"])
        #expect(Userscript.newer("3.10.0", than: "3.9.2"))
        #expect(!Userscript.newer("1.0", than: "1.0.0"))
        #expect(Userscript.newer("2026.07.22.1", than: "2025.5.22.1"))
    }

    @Test func onlyTampermonkeyKeepsCookieScripts() throws {
        let cookies = try Userscript.read(Self.script(["@name K", "@match https://example.com/*", "@grant GM_cookie"]))
        #expect(cookies.onlyTampermonkey == ["GM_cookie"])
        #expect(UserscriptMove.stays(cookies) == "Stays in Tampermonkey: reads your cookies")
    }

    @Test func tampermonkeyStorageIsRead() {
        let source = Self.script(["@name Moved", "@namespace yab-test", "@match https://example.com/*", "@grant GM_setValue"])
        let items = UserscriptMove.parseTampermonkey([
            "@source#abc": ["value": source],
            "@meta#abc": ["value": ["enabled": false]],
            "@st#abc": ["value": ["data": ["count": 3]]],
            "@uid#x": "unrelated",
        ])
        #expect(items.count == 1)
        #expect(items.first?.script.name == "Moved")
        #expect(items.first?.enabled == false)
        #expect(items.first?.values["count"] as? Int == 3)
    }

    /// Tampermonkey 5.5, as read in Yab: `!extdb.` keys, typed values.
    @Test func tampermonkeyFiveStorageIsRead() {
        let source = Self.script(["@name Moved", "@namespace yab-test", "@match https://example.com/*", "@grant GM_setValue"])
        let uuid = "ad1579ea-8241-4730-bd7b-4ab4e78c77f2"
        let items = UserscriptMove.parseTampermonkey([
            "!extdb.@source#" + uuid: ["origin": "normal", "value": source],
            "!extdb.@meta#" + uuid: ["origin": "normal", "value": ["enabled": true, "version": "1.0"]],
            "!extdb.@st#" + uuid: ["origin": "normal", "value": ["data": ["seen": "n1", "name": "sYab"], "ts": 1]],
            "!extdb.@uid#" + uuid: ["origin": "normal", "value": "Moved"],
        ])
        #expect(items.count == 1)
        #expect(items.first?.values["seen"] as? Double == 1)
        #expect(items.first?.values["name"] as? String == "Yab")
        #expect(items.first?.tampermonkeyID == uuid)
    }

    /// Tampermonkey's registered code for a moved script is left out: by
    /// its uuid, or by its header even inside a JS string.
    @Test func movedScriptIsKnownInTampermonkeysCode() {
        let known: Set<String> = ["yab-test\nMoved", "ad1579ea-8241-4730-bd7b-4ab4e78c77f2"]
        #expect(UserscriptMove.movedOut("run({uuid: 'ad1579ea-8241-4730-bd7b-4ab4e78c77f2'})", known: known))
        #expect(UserscriptMove.movedOut(#"const s = "// ==UserScript==\n// @name Moved\n// @namespace yab-test\n// ==/UserScript==\n";"#, known: known))
        #expect(!UserscriptMove.movedOut(#"const s = "// ==UserScript==\n// @name Other\n// @namespace yab-test\n// ==/UserScript==\n";"#, known: known))
    }

    @Test func violentmonkeyValuesAreDecoded() throws {
        let script = try Userscript.read(Self.script(["@name V", "@namespace ns", "@match https://example.com/*"]))
        let (values, on) = UserscriptMove.violentValues(["values": ["ns\nV\n": ["a": "sword", "b": "n4", "c": "btrue", "d": #"o{"x":1}"#]],
                                                         "scripts": ["V": ["config": ["enabled": 0]]]], script: script, stem: "V")
        #expect(values["a"] as? String == "word")
        #expect(values["b"] as? Double == 4)
        #expect(values["c"] as? Bool == true)
        #expect((values["d"] as? [String: Any])?["x"] as? Int == 1)
        #expect(on == false)
    }

    @Test func runtimeWrapsTheCodeAndItsRules() throws {
        let script = try Userscript.read(Self.dislike)
        let source = UserscriptRuntime.source(script, id: "ryd", values: ["x": 1], inPage: false, token: "t", appVersion: "0.0.23")
        #expect(source.contains("yab-userscript: ryd"))
        #expect(source.contains(#""scriptHandler":"Yab""#))
        #expect(source.contains("const API_BASE_URL"))
        #expect(source.contains(#"messageHandlers["yabUserscript"]"#))
        let page = UserscriptRuntime.source(script, id: "ryd-1", values: [:], inPage: true, token: "t", appVersion: "0.0.23")
        #expect(page.contains("yabUserscript_ryd_1"))
    }

    @Test func codeHostsSkipLinksAndComments() {
        let hosts = Userscript.codeHosts("""
        // fetch('https://commented.example/x')
        const help = "https://docs.example.com/help";
        GM_xmlhttpRequest({ url: "https://api.example.net/v1" });
        """)
        #expect(hosts == ["api.example.net"])
    }

    /// A `.user.js` clicked in a page reaches Yab already sent to
    /// Tampermonkey's install page by its rule; the script is read back out.
    @Test func tampermonkeyInstallPageGivesTheScript() {
        let script = "https://update.greasyfork.org/scripts/436115/Return%20YouTube%20Dislike.user.js"
        let page = URL(string: Userscripts.tampermonkeyInstall + script)!
        #expect(Userscripts.behindTampermonkey(page)?.absoluteString == script)
        #expect(Userscripts.behindTampermonkey(URL(string: "https://www.tampermonkey.net/faq.php#url=x")!) == nil)
        #expect(Userscripts.behindTampermonkey(URL(string: script)!) == nil)
    }
}
