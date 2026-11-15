import Testing
import YabCoreClient
@testable import Fast

@Suite(.serialized) @MainActor
struct ChromiumFileSourceTests {
    private var frame: JSONValue {
        .object(["token": .string("document-1"), "frameId": .string("iframe-1"),
                 "main": .bool(false), "url": .string("https://upload.example/form"),
                 "scheme": .string("https"), "host": .string("upload.example"), "port": .number(443)])
    }
    private func request(_ frame: JSONValue) -> [String: JSONValue] {
        ["tab": .string("tab-1"), "request": .string("pick-1"),
         "source": .object(["version": .number(1), "request": .string("pick-1"), "frame": frame])]
    }

    @Test func childSourceKeepsItsDocumentAndPageOwnership() throws {
        let scripts = ChromiumScripts(), other = ChromiumScripts()
        let child = try #require(scripts.fileFrame(request(frame), tab: "tab-1"))
        #expect(!child.isMain && child.origin.host == "upload.example")
        #expect(try scripts.token(child, tab: "tab-1") == "document-1")
        #expect(throws: PageEngineError.self) { try other.token(child, tab: "tab-1") }
        #expect(throws: PageEngineError.self) { try scripts.token(child, tab: "tab-2") }
        var main = frame.object!
        main["main"] = .bool(true)
        #expect(scripts.fileFrame(request(.object(main)), tab: "tab-1")?.isMain == true)
    }

    @Test func absentOrUncorrelatedSourceKeepsPanelFallback() {
        let scripts = ChromiumScripts()
        var p = request(frame)
        p.removeValue(forKey: "source")
        #expect(scripts.fileFrame(p, tab: "tab-1") == nil)
        p = request(frame)
        p["request"] = .string("pick-2")
        #expect(scripts.fileFrame(p, tab: "tab-1") == nil)
        #expect(scripts.fileFrame(request(frame), tab: "tab-2") == nil)
        #expect(scripts.fileFrame(request(frame), tab: nil) == nil)
        p = request(frame)
        p["source"] = .object(["version": .number(2), "request": .string("pick-1"), "frame": frame])
        #expect(scripts.fileFrame(p, tab: "tab-1") == nil)
    }

    @Test func malformedNativeFrameNeverBecomesMainFrame() {
        let scripts = ChromiumScripts()
        for field in ["token", "frameId", "main", "url", "scheme", "host", "port"] {
            var value = frame.object!
            value.removeValue(forKey: field)
            #expect(scripts.fileFrame(request(.object(value)), tab: "tab-1") == nil)
        }
        for (field, bad) in [("token", JSONValue.string("")), ("main", .number(1)),
                             ("port", .number(-1)), ("port", .number(65536)), ("port", .number(1.5))] {
            var value = frame.object!
            value[field] = bad
            #expect(scripts.fileFrame(request(.object(value)), tab: "tab-1") == nil)
        }
    }
}
