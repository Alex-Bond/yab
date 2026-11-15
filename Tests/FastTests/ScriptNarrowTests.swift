import Foundation
import JavaScriptCore
import Testing
@testable import Fast

/// Extensions' scripts narrowed to Latin-1 mean what they meant
/// (ScriptNarrow): each case is run before and after, and must give the
/// same value.
@Suite
struct ScriptNarrowTests {
    private func value(_ script: String) throws -> String? {
        let context = try #require(JSContext())
        let result = context.evaluateScript(script)
        #expect(context.exception == nil, "\(context.exception?.toString() ?? "")")
        return result?.toString()
    }

    private func latin1(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { $0.value <= 0xFF } }

    @Test(arguments: [
        // A string, single and double quotes.
        #"'Saving…' + "→""#,
        // A template, with a value in it.
        #"`${1 + 1} items · ${'∞'}`"#,
        // A pattern, a class of them and a range.
        #"String(/…+/.test('a……b')) + String(/[→–]/.test('–')) + 'x→y'.replace(/[\u2190-→]/g, '-')"#,
        // A comment, on its own line and after code.
        "// Ships with “quotes”\n'ok' /* → */",
        // A name made of letters past Latin-1.
        "var π = 3; var Ωmega = π * 2; String(Ωmega)",
        // Past the basic plane: a string, a pattern with u, and one without.
        #"'😀'.length + ':' + /^.$/u.test('😀') + ':' + /^😀$/.test('😀') + ':' + '😀'.codePointAt(0)"#,
        // An escape of the character itself: `\…` is `…`.
        #"'\…' === '…' ? 'same' : 'differs'"#,
        // An escaped backslash and then the character: both stay.
        #"'\\…'.length + ':' + '\\…'"#,
        // Latin-1 itself stays as it is.
        "'café ñ ü' + '→'",
    ])
    func meansTheSame(_ script: String) throws {
        let narrow = try #require(ScriptNarrow.narrowed(script))
        #expect(latin1(narrow))
        #expect(try value(narrow) == value(script))
    }

    @Test func aScriptAllLatin1IsLeftAlone() {
        #expect(ScriptNarrow.narrowed("var a = 'café'; // plain\n") == nil)
    }

    @Test func aByteOrderMarkGoes() throws {
        let narrow = try #require(ScriptNarrow.narrowed("\u{FEFF}var a = 1; a"))
        #expect(narrow == "var a = 1; a")
    }

    @Test func aLineSeparatorLeavesTheScriptAsItIs() {
        // In a comment it ends the line, which its escape wouldn't.
        #expect(ScriptNarrow.narrowed("// a\u{2028}var a = '…'") == nil)
        #expect(ScriptNarrow.narrowed("var a = '\u{2029}…'") == nil)
    }

    @Test func rawTemplatesLeaveTheScriptAsItIs() {
        #expect(ScriptNarrow.narrowed("String.raw`…`") == nil)
    }

    @Test func aScriptThatWouldNoLongerParseIsLeftAsItIs() throws {
        let context = JSGlobalContextCreate(nil)!
        defer { JSGlobalContextRelease(context) }
        // An ideographic space between two words is a space; its escape isn't.
        #expect(ScriptNarrow.checked("var\u{3000}a = 1", in: context) == nil)
        // A module isn't a content script's syntax: not checked, not touched.
        #expect(ScriptNarrow.checked("import x from './x.js'; '…'", in: context) == nil)
        #expect(ScriptNarrow.checked("var a = '…'", in: context) == "var a = '\\u2026'")
    }

    @Test func aPackageIsNarrowedButYabsOwnFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-narrow-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("js"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wide = "document.title = 'Saving…';\n"
        try wide.write(to: folder.appendingPathComponent("js/content.js"), atomically: true, encoding: .utf8)
        try wide.write(to: folder.appendingPathComponent(ExtensionShims.content), atomically: true, encoding: .utf8)
        try "export const a = '…';\n".write(to: folder.appendingPathComponent("module.js"), atomically: true, encoding: .utf8)
        try "body::after { content: '…' }\n".write(to: folder.appendingPathComponent("page.css"), atomically: true, encoding: .utf8)
        #expect(ScriptNarrow.narrow(folder: folder, except: [ExtensionShims.content]) == 1)
        #expect(try String(contentsOf: folder.appendingPathComponent("js/content.js"), encoding: .utf8) == "document.title = 'Saving\\u2026';\n")
        #expect(try String(contentsOf: folder.appendingPathComponent(ExtensionShims.content), encoding: .utf8) == wide)
        #expect(try String(contentsOf: folder.appendingPathComponent("module.js"), encoding: .utf8) == "export const a = '…';\n")
        #expect(try String(contentsOf: folder.appendingPathComponent("page.css"), encoding: .utf8) == "body::after { content: '…' }\n")
    }

    @MainActor
    @Test func prepareNarrowsAContentScript() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("script-narrow-prepare-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try #"{"manifest_version":3,"name":"Narrow","version":"1.0","content_scripts":[{"matches":["<all_urls>"],"js":["page.js"]}]}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try "globalThis.label = 'Loading…';\n".write(to: folder.appendingPathComponent("page.js"), atomically: true, encoding: .utf8)
        try ExtensionShims.prepare(folder, fresh: true)
        let page = try String(contentsOf: folder.appendingPathComponent("page.js"), encoding: .utf8)
        #expect(page == "globalThis.label = 'Loading\\u2026';\n")
    }
}
