import Foundation
import JavaScriptCore
import Testing
@testable import Fast

// Resources/PageScripts: every file is found, parses in JavaScriptCore, the
// engine pages run it in, and is one the sources load.
struct PageScriptTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/PageScripts")
    static let names: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter { $0.hasSuffix(".js") }.map { String($0.dropLast(3)) }.sorted()

    @Test func theFolderIsThere() {
        #expect(Self.names.count >= 16)
    }

    @Test(arguments: names) func loadsAndParses(_ name: String) throws {
        #expect(PageScript.url(name) != nil)
        let text = PageScript.load(name)
        #expect(!text.isEmpty)
        #expect(!text.hasSuffix("\n"), "the file's last newline is the file's, not the script's")
        // A whole program, or the body of the function yab wraps it in
        // (measure.js, call-stage.js). __YAB_KEY__ markers are identifiers.
        let context = try #require(JSContext())
        func parses(_ source: String) -> Bool {
            let script = JSStringCreateWithCFString(source as CFString)
            defer { JSStringRelease(script) }
            var exception: JSValueRef?
            let ok = JSCheckScriptSyntax(context.jsGlobalContextRef, script, nil, 1, &exception)
            return ok
        }
        #expect(parses(text) || parses("(async function () {\n" + text + "\n})"), "\(name).js doesn't parse")
    }

    @Test(arguments: names) func theSourcesLoadIt(_ name: String) throws {
        let sources = Self.folder.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources/Fast")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let call = "PageScript.load(\"\(name)\""
        #expect(try files.contains { try String(contentsOf: $0, encoding: .utf8).contains(call) }, "nothing loads \(name).js")
    }
}
