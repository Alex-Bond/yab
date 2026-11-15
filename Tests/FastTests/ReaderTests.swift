import Foundation
import JavaScriptCore
import Testing
@testable import Fast

// Reading mode's scripts are Swift strings until WebKit runs them, where a
// backslash lost in the escaping or a stray brace fails silently: ⌥⌘R would
// just say there is no article. Each one has to parse.
struct ReaderTests {
    static func parses(_ source: String) -> String? {
        let context = JSGlobalContextCreate(nil)
        defer { JSGlobalContextRelease(context) }
        let script = JSStringCreateWithUTF8CString(source)
        defer { JSStringRelease(script) }
        var exception: JSValueRef?
        guard !JSCheckScriptSyntax(context, script, nil, 1, &exception) else { return nil }
        guard let exception, let text = JSValueToStringCopy(context, exception, nil) else { return "unknown" }
        defer { JSStringRelease(text) }
        return JSStringCopyCFString(nil, text) as String
    }

    @Test func enterParses() { #expect(Self.parses(Reader.enter) == nil) }
    @Test func asyncArticleScriptsParse() {
        for script in [Reader.readableWhenReady, Reader.enterWhenReady] {
            #expect(Self.parses("(async function () {" + script + "})") == nil)
        }
    }
    @Test func leaveParses() { #expect(Self.parses(Reader.leave) == nil) }
    @Test func showingParses() { #expect(Self.parses(Reader.showing) == nil) }
    @Test func readableParses() { #expect(Self.parses(Reader.readable) == nil) }
    @Test func themeParses() {
        var prefs = ReaderPrefs()
        prefs.change { $0.colors = ReaderColors("123456", "abcdef") }
        #expect(Self.parses(Reader.configure(prefs)) == nil)
        for id in ReaderThemeID.allCases {
            prefs.theme = id
            #expect(Self.parses(Reader.configure(prefs)) == nil)
        }
    }
    @Test func unreadableCustomInkGetsContrastingFallback() {
        for level in stride(from: 0, through: 255, by: 5) {
            let hex = String(format: "%02x%02x%02x", level, level, level)
            let colors = ReaderColors(hex, hex)
            #expect(ReaderColors.contrast(colors.background, colors.text) >= 4.5)
        }
    }
    @Test func customColorsAreValidatedAndRetained() {
        let colors = ReaderColors("#1C1C1E", "E5E5E7")
        #expect(colors.background == "#1c1c1e")
        #expect(colors.text == "#e5e5e7")
        #expect(colors.dark)
        #expect(ReaderColors("red;}", "bad").background == "#ffffff")
        #expect(ReaderColors.hex("123456;}") == nil)
    }
}
