import Foundation
import Testing
@testable import Fast

// The Network panel (DevNet.swift and its parts): WebKit's resources as
// rows, the phases of a request, the filter's words, the copies in the
// usual DevTools formats, HAR out and back in, cookies, Server Timing and a
// JSON body in its own order.
struct DevNetTests {
    private func batch(_ object: [String: Any]) -> NetBatch {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return NetBatch.parse(String(data: data, encoding: .utf8)!)!
    }

    private func resource(_ id: Int, _ url: String, status: Int = 200, type: String = "fetch", extra: [String: Any] = [:]) -> [String: Any] {
        var r: [String: Any] = ["i": id, "u": url, "m": "GET", "y": type, "st": status, "sx": status == 200 ? "OK" : "", "dn": true,
                                "ts": 100.0 + Double(id), "wt": 1_800_000_000.0 + Double(id), "en": 100.5 + Double(id),
                                "tm": ["s": 100.0 + Double(id), "f": 100.001 + Double(id), "qs": 100.002 + Double(id), "ps": 100.050 + Double(id), "pe": 100.060 + Double(id)]]
        for (k, v) in extra { r[k] = v }
        return r
    }

    @MainActor @Test func aRedirectIsARowForEachHop() {
        let log = NetLog()
        log.apply(batch(["r": [resource(1, "https://a.test/final", extra: [
            "rd": [["u": "https://a.test/start", "m": "GET", "st": 302, "sx": "Found", "phd": [["Location", "/next"]], "at": 101.010],
                   ["u": "https://a.test/next", "m": "GET", "st": 301, "sx": "Moved Permanently", "at": 101.020]],
        ])]]))
        log.flush()
        #expect(log.rows.map(\.url) == ["https://a.test/start", "https://a.test/next", "https://a.test/final"])
        #expect(log.rows.map(\.status) == [302, 301, 200])
        #expect(log.rows[0].typeLabel == "Redirect")
        // Where it ended came from the hop before, as an initiator column says.
        #expect(log.rows[2].from == log.rows[1].id)
        #expect(log.rows[2].initiatorLabel.kind == "Redirect")
        #expect(log.rows[2].initiatorLabel.place == "next")
        // A hop's time is from the one before to its own redirect.
        #expect(abs((log.rows[1].duration ?? 0) - 10) < 0.01)
        // Ids stay put as the resource changes.
        let ids = log.rows.map(\.id)
        log.apply(batch(["r": [["i": 1, "sz": 512]]]))
        log.flush()
        #expect(log.rows.map(\.id) == ids)
        #expect(log.rows[2].size == 512)
    }

    @Test func phasesAreChromesFromWebKitsTiming() {
        let timing = NetResource.Timing(start: 10, redirectStart: nil, redirectEnd: nil, fetchStart: 10.001, dnsStart: 10.002, dnsEnd: 10.012,
                                        connectStart: 10.012, connectEnd: 10.040, secureStart: 10.020, requestStart: 10.041, responseStart: 10.141, responseEnd: 10.151)
        let phases = NetPhases(timing, ended: nil)!
        #expect(abs(phases.queueing - 1) < 0.001)
        #expect(abs(phases.stalled - 1) < 0.001)
        #expect(abs(phases.dns - 10) < 0.001)
        #expect(abs(phases.connecting - 8) < 0.001)
        #expect(abs(phases.ssl - 20) < 0.001)
        #expect(abs(phases.initialConnection - 28) < 0.001)
        #expect(abs(phases.sending - 1) < 0.001)
        #expect(abs(phases.waiting - 100) < 0.001)
        #expect(abs(phases.download - 10) < 0.001)
        #expect(abs(phases.latency - 141) < 0.01)
        // A reused connection: nothing looked up, nothing connected.
        let reused = NetPhases(NetResource.Timing(start: 1, fetchStart: 1, requestStart: 1.003, responseStart: 1.020, responseEnd: 1.021), ended: nil)!
        #expect(reused.dns == 0 && reused.initialConnection == 0)
        #expect(abs(reused.stalled - 3) < 0.001)
        // Nothing measured: none to draw.
        #expect(NetPhases(NetResource.Timing(), ended: nil) == nil)
    }

    @MainActor @Test func aNewPageClearsTheLogUnlessItIsKept() {
        let log = NetLog()
        log.apply(batch(["r": [resource(1, "https://a.test/", type: "document", extra: ["ld": "L1"]), resource(2, "https://a.test/app.js", type: "script", extra: ["ld": "L1"])]]))
        log.apply(batch(["nav": "L2", "r": [resource(3, "https://a.test/next", type: "document", extra: ["ld": "L2"])]]))
        log.flush()
        #expect(log.rows.map(\.url) == ["https://a.test/next"])
        // A fast page says it came and loaded in one batch: the moments are its own.
        log.apply(batch(["nav": "L3", "pg": ["dcl": 103.2, "load": 103.4], "r": [resource(4, "https://a.test/fast", type: "document", extra: ["ld": "L3"])]]))
        #expect(log.contentLoaded == 103.2 && log.loaded == 103.4)
        let kept = NetLog()
        kept.keepLog = { true }
        kept.apply(batch(["r": [resource(1, "https://a.test/", extra: ["ld": "L1"])]]))
        kept.apply(batch(["nav": "L2", "r": [resource(3, "https://a.test/next", extra: ["ld": "L2"])]]))
        kept.flush()
        #expect(kept.rows.count == 2)
        // Record off: nothing new comes in.
        kept.recording = false
        kept.apply(batch(["r": [resource(4, "https://a.test/late")]]))
        kept.flush()
        #expect(kept.rows.count == 2)
    }

    private func row(_ url: String, status: Int = 200, type: String = "fetch", mime: String = "application/json", method: String = "GET",
                     transferred: Int = 1200, headers: [NetHeader] = [], requestHeaders: [NetHeader] = [], finished: Bool = true) -> NetRow {
        var r = NetResource(id: 7)
        r.url = url; r.status = status; r.type = type; r.mime = mime; r.method = method; r.transferred = transferred
        r.responseHeaders = headers; r.requestHeaders = requestHeaders; r.finished = finished
        r.timing = NetResource.Timing(start: 1, fetchStart: 1, requestStart: 1, responseStart: 1.01, responseEnd: 1.02)
        return NetRow(id: 1, resource: r, hop: nil, from: nil)
    }

    @Test func theFilterReadsChromesWords() {
        let page = URL(string: "http://localhost:5173/")
        let none: (String) -> String? = { _ in nil }
        let api = row("https://api.tern.app/v1/slots?team=t_42", headers: [NetHeader(name: "Server", value: "cloudflare")])
        let local = row("http://localhost:5173/api/testimonials", status: 500, method: "POST", transferred: 412)
        let picture = row("http://localhost:5173/hero.png", type: "image", mime: "image/png", transferred: 84_000)
        func shown(_ text: String, invert: Bool = false) -> [String] {
            var filter = NetFilter()
            filter.text = text
            filter.invert = invert
            return [api, local, picture].filter { filter.admits($0, page: page, overridden: none) }.map(\.name)
        }
        #expect(shown("domain:*.tern.app") == ["slots?team=t_42"])
        #expect(shown("status-code:500") == ["testimonials"])
        #expect(shown("-method:GET") == ["testimonials"])
        #expect(shown("larger-than:10k") == ["hero.png"])
        #expect(shown("/test.*s$/") == ["testimonials"])
        #expect(shown("has-response-header:server") == ["slots?team=t_42"])
        #expect(shown("localhost") == ["testimonials", "hero.png"])
        #expect(shown("localhost", invert: true) == ["slots?team=t_42"])
        #expect(shown("mime-type:image/png method:GET") == ["hero.png"])
        var types = NetFilter()
        types.types = [.img, .fetch]
        #expect([api, local, picture].filter { types.admits($0, page: page, overridden: none) }.count == 3)
        types.types = [.img]
        #expect([api, local, picture].filter { types.admits($0, page: page, overridden: none) }.map(\.name) == ["hero.png"])
        var third = NetFilter()
        third.onlyThirdParty = true
        #expect([api, local, picture].filter { third.admits($0, page: page, overridden: none) }.map(\.name) == ["slots?team=t_42"])
        var data = NetFilter()
        data.hideData = true
        #expect(!data.admits(row("data:image/svg+xml;base64,AAA"), page: page, overridden: none))
    }

    @Test func theFieldCompletesKeysAndWhatWasSeen() {
        let rows = [row("https://api.tern.app/a", method: "POST"), row("http://localhost:5173/b")]
        #expect(NetFilter.completions("sta", rows: rows) == ["status-code:"])
        #expect(NetFilter.completions("method:p", rows: rows) == ["method:POST"])
        #expect(NetFilter.completions("domain:", rows: rows) == ["domain:api.tern.app", "domain:localhost"])
        #expect(NetFilter.completions("-is:r", rows: rows) == ["is:running"])
        #expect(NetFilter.completions("x ", rows: rows).isEmpty)
    }

    @Test func copiesAreChromes() {
        var r = row("https://api.tern.app/v1/holds", method: "POST", requestHeaders: [
            NetHeader(name: ":authority", value: "api.tern.app"), NetHeader(name: "Content-Type", value: "application/json"),
            NetHeader(name: "Cookie", value: "sid=1; theme=dark"), NetHeader(name: "Accept-Encoding", value: "gzip, br"),
            NetHeader(name: "Content-Length", value: "12"), NetHeader(name: "Referer", value: "http://localhost:5173/"),
            NetHeader(name: "Sec-Fetch-Mode", value: "cors"), NetHeader(name: "Authorization", value: "Bearer abc"),
        ]).resource
        r.postData = #"{"slot":"it's"}"#
        r.referrerPolicy = "strict-origin-when-cross-origin"
        let post = NetRow(id: 1, resource: r, hop: nil, from: nil)
        let curl = NetCopy.curl(post)
        #expect(curl.hasPrefix("curl 'https://api.tern.app/v1/holds'"))
        #expect(curl.contains("-X 'POST'"))
        #expect(curl.contains("-b 'sid=1; theme=dark'"))
        #expect(curl.contains("--compressed"))
        #expect(!curl.contains(":authority") && !curl.contains("content-length"))
        #expect(curl.contains(#"--data-raw '{"slot":"it'\''s"}'"#))
        let fetch = NetCopy.fetch(post, node: false)
        #expect(fetch.contains(#""credentials": "include""#))
        #expect(fetch.contains(#""referrer": "http://localhost:5173/""#))
        #expect(!fetch.contains("cookie") && !fetch.contains("sec-fetch"))
        #expect(fetch.contains(#""authorization": "Bearer abc""#))
        let node = NetCopy.fetch(post, node: true)
        #expect(node.contains(#""cookie": "sid=1; theme=dark""#))
        #expect(!node.contains("credentials"))
        #expect(NetCopy.preload(post) == nil)
        #expect(NetCopy.preload(row("https://cdn.test/app.js", type: "script")) == #"<link rel="preload" href="https://cdn.test/app.js" as="script">"#)
        // For an agent, cookies and keys are out.
        let agent = NetCopy.agent([post], bodies: [:], page: URL(string: "http://localhost:5173/"))
        #expect(agent.contains("Cookie: [removed]") && agent.contains("Authorization: [removed]"))
        #expect(!agent.contains("sid=1"))
    }

    @Test func harGoesOutSanitizedAndComesBack() throws {
        var r = row("https://api.tern.app/v1/me", headers: [NetHeader(name: "Set-Cookie", value: "sid=2; HttpOnly"), NetHeader(name: "Content-Type", value: "application/json")],
                    requestHeaders: [NetHeader(name: "Cookie", value: "sid=1"), NetHeader(name: "Accept", value: "*/*")]).resource
        r.wall = 1_800_000_000
        r.sent = 1
        r.proto = "h2"
        r.remote = "104.18.22.7:443"
        r.priority = "high"
        let rows = [NetRow(id: 1, resource: r, hop: nil, from: nil)]
        let bodies = [7: NetBody(text: #"{"id":"u_1"}"#, base64: false)]
        let sanitized = NetHAR.archive(rows, bodies: bodies, page: URL(string: "http://localhost:5173/"), contentLoaded: 1.2, loaded: 1.5, sanitized: true)
        let text = String(data: try #require(NetHAR.data(sanitized)), encoding: .utf8)!
        #expect(!text.contains("sid=1") && !text.contains("sid=2"))
        #expect(text.contains(#""serverIPAddress" : "104.18.22.7""#))
        let full = try #require(NetHAR.data(NetHAR.archive(rows, bodies: bodies, page: nil, contentLoaded: nil, loaded: nil, sanitized: false)))
        let back = try #require(NetHAR.resources(from: full))
        #expect(back.count == 1)
        #expect(back[0].url == "https://api.tern.app/v1/me")
        #expect(back[0].status == 200)
        #expect(back[0].requestHeaders.value("cookie") == "sid=1")
        #expect(back[0].imported)
        let phases = try #require(NetPhases(back[0].timing, ended: back[0].ended))
        #expect(abs(phases.waiting - 10) < 0.5)
    }

    @Test func cookiesAreReadAsChromeShowsThem() {
        let r = row("https://a.test/", headers: [NetHeader(name: "Set-Cookie", value: "sid=abc; Path=/app; HttpOnly; Secure; SameSite=Lax; Max-Age=60\n=broken")],
                    requestHeaders: [NetHeader(name: "Cookie", value: "a=1; b=2")])
        let request = NetCookie.request(r)
        #expect(request.map(\.name) == ["a", "b"])
        let response = NetCookie.response(r)
        #expect(response.cookies.count == 1)
        #expect(response.cookies[0].httpOnly && response.cookies[0].secure && response.cookies[0].sameSite == "Lax")
        #expect(response.cookies[0].path == "/app" && response.cookies[0].expires == "60")
        #expect(response.malformed == ["=broken"])
    }

    @Test func serverTimingIsReadOffItsHeader() {
        let entries = NetServerTiming.parse(#"db;dur=38.2;desc="Postgres", cache;desc=miss, render;dur=4.1"#)
        #expect(entries.map(\.name) == ["db", "cache", "render"])
        #expect(entries[0].duration == 38.2 && entries[0].description == "Postgres")
        #expect(entries[1].duration == nil && entries[1].description == "miss")
    }

    @Test func jsonKeepsItsOrder() throws {
        let json = try #require(NetJSON.parse(#"{"z":1,"a":[true,null,"x"],"m":{"k":-2.5e3}}"#))
        guard case .object(let pairs) = json else { Issue.record("not an object"); return }
        #expect(pairs.map(\.0) == ["z", "a", "m"])
        #expect(json.pretty().hasPrefix("{\n  \"z\": 1,\n  \"a\": [\n    true,"))
        #expect(NetJSON.parse("not json") == nil)
        #expect(NetJSON.parse(#"{"a":1} trailing"#) == nil)
        #expect(json.preview == "{z: 1, a: Array(3), m: {…}}")
    }

    /// #378: Response lays JSON out indented, every token as written.
    @Test func responsePrettyPrintsJSONAsChrome() throws {
        let minified = #"{"z":1,"a":[true,null,"x\"y\/z"],"m":{"k":-2.5e3},"e":{},"l":[]}"#
        let laid = try #require(NetPretty.auto(minified, mime: "application/json"))
        #expect(laid == """
        {
          "z": 1,
          "a": [
            true,
            null,
            "x\\"y\\/z"
          ],
          "m": {
            "k": -2.5e3
          },
          "e": {},
          "l": []
        }
        """)
        // Laid out already as it would be: nothing to do.
        #expect(NetPretty.auto(laid, mime: "application/json") == nil)
        // Whatever the type says, JSON is laid out.
        #expect(NetPretty.auto(#"[1,2]"#, mime: "text/plain") == "[\n  1,\n  2\n]")
        // A short script isn't minified; a long line is.
        #expect(NetPretty.auto("let a = 1;\nlet b = 2;", mime: "text/javascript") == nil)
        #expect(NetPretty.auto("var a=1;" + String(repeating: "f();", count: 200), mime: "text/javascript") != nil)
        #expect(NetPretty.auto("plain words", mime: "text/plain") == nil)
    }

    /// #378: guarded replies and JSONP read as JSON in the preview.
    @Test func previewReadsGuardedAndJSONPReplies() throws {
        let guarded = try #require(NetJSON.reply(")]}'\n{\"a\":[1]}"))
        #expect(guarded.prefix == ")]}'" && guarded.suffix.isEmpty)
        #expect(guarded.value == .object([("a", .array([.number("1")]))]))
        let jsonp = try #require(NetJSON.reply("cb.done({\"ok\":true});"))
        #expect(jsonp.prefix == "cb.done(" && jsonp.suffix == ");")
        #expect(NetJSON.reply("\u{FEFF}  [1]")?.value == .array([.number("1")]))
        #expect(NetJSON.reply("alert(1)") == nil)
        #expect(NetJSON.reply("<html></html>") == nil)
        #expect(NetPretty.auto(")]}'\n{\"a\":1}", mime: "application/json") == ")]}'\n{\n  \"a\": 1\n}")
        #expect(NetPretty.auto("cb({\"a\":1})", mime: "application/javascript") == "cb({\n  \"a\": 1\n})")
    }

    /// #378: JSON WebKit handed over as bytes (a vendor type) reads as words.
    @Test func base64JSONReadsAsWords() {
        let bytes = Data(#"{"data":{"id":"1"}}"#.utf8).base64EncodedString()
        let body = NetBody(text: bytes, base64: true, error: nil)
        #expect(body.readable(mime: "application/vnd.api").base64 == false)
        #expect(body.readable(mime: "application/vnd.api").text == #"{"data":{"id":"1"}}"#)
        #expect(body.readable(mime: "application/vnd.api+json").text == #"{"data":{"id":"1"}}"#)
        let png = NetBody(text: "iVBORw0KGgo=", base64: true, error: nil)
        #expect(png.readable(mime: "image/png").base64)
        let binary = NetBody(text: Data([0xFF, 0xFE, 0x00, 0x81]).base64EncodedString(), base64: true, error: nil)
        #expect(binary.readable(mime: "application/octet-stream").base64)
    }

    @Test func sizesTimesAndPlaces() {
        #expect(NetFormat.size(812) == "812 B")
        #expect(NetFormat.size(1234) == "1.2 kB")
        #expect(NetFormat.size(43_710) == "44 kB")
        #expect(NetFormat.size(1_600_000) == "1.6 MB")
        #expect(NetFormat.time(0.42) == "0.42 ms")
        #expect(NetFormat.time(12.4) == "12 ms")
        #expect(NetFormat.time(1234) == "1.23 s")
        #expect(NetAddress.space("[::1]:5173") == "Loopback")
        #expect(NetAddress.space("192.168.1.4:80") == "Local")
        #expect(NetAddress.space("172.20.0.1:80") == "Local")
        #expect(NetAddress.space("104.18.22.7:443") == "Public")
    }

    @Test func sortingKeepsTheHeardOrderForTies() {
        var a = row("https://a.test/1", status: 200).resource; a.id = 1
        var b = row("https://a.test/2", status: 500).resource; b.id = 2
        var c = row("https://a.test/3", status: 200).resource; c.id = 3
        let rows = [a, b, c].map { NetRow(id: $0.id, resource: $0, hop: nil, from: nil) }
        #expect(NetPanel.sorted(rows, by: NetSort(column: "status", ascending: true)).map(\.id) == [1, 3, 2])
        #expect(NetPanel.sorted(rows, by: NetSort(column: "status", ascending: false)).map(\.id) == [2, 1, 3])
        #expect(NetPanel.sorted(rows, by: NetSort(column: "name", ascending: false)).map(\.id) == [3, 2, 1])
    }

    @Test func aStatusSaysWhatChromeSays() {
        var r = row("https://a.test/x").resource
        r.finished = false
        #expect(NetRow(id: 1, resource: r, hop: nil, from: nil).statusLabel == "(pending)")
        r.failed = true
        r.failure = "Could not connect to the server."
        #expect(NetRow(id: 1, resource: r, hop: nil, from: nil).statusLabel == "(failed)")
        r.failure = "Origin http://localhost:5173 is not allowed by Access-Control-Allow-Origin."
        #expect(NetRow(id: 1, resource: r, hop: nil, from: nil).statusLabel == "CORS error")
        r.blockedBy = "devtools"
        #expect(NetRow(id: 1, resource: r, hop: nil, from: nil).statusLabel == "(blocked:devtools)")
        var socket = row("ws://localhost:5173/", status: 101, type: "websocket", finished: false).resource
        socket.status = 101
        #expect(NetRow(id: 1, resource: socket, hop: nil, from: nil).statusLabel == "101")
        #expect(NetRow(id: 1, resource: socket, hop: nil, from: nil).duration == nil)
    }
}
