import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor
struct SelectionRichEditorTests {
    // PageView owns its undo manager even outside a window. Keep that
    // editing contract without initializing its unrelated page scripts.
    final class EditorView: WKWebView {
        private let edits = UndoManager()
        override var undoManager: UndoManager? { edits }
    }

    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done?.resume(); done = nil
        }
    }

    static func page(_ html: String) async -> WKWebView {
        let web = EditorView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { go in
            loaded.done = go
            web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        }
        web.navigationDelegate = nil
        return web
    }

    @Test @MainActor func richEditorRebuildKeepsUnchangedSelection() async throws {
        let web = await Self.page("<div id=editor contenteditable=true><p>Hello old world</p></div><input id=other>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('editor'); e.focus();
        const r = document.createRange(); r.setStart(e.firstChild.firstChild, 6); r.setEnd(e.firstChild.firstChild, 9);
        getSelection().removeAllRanges(); getSelection().addRange(r); true
        """)
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("document.getElementById('other').focus(); document.getElementById('editor').innerHTML = '<p>Hello <b>old</b> world</p>'; true")
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('new')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "ok")
        #expect(try await web.evaluateJavaScript("document.getElementById('editor').textContent") as? String == "Hello new world")
        let undone = try await web.evaluateJavaScript("window.__yabUndoSelection()", in: nil, contentWorld: .defaultClient) as? String
        #expect(undone == "ok")
        #expect(try await web.evaluateJavaScript("document.getElementById('editor').textContent") as? String == "Hello old world")
    }

    @Test @MainActor func richEditorRebuildDoesNotOverwriteEditedDraft() async throws {
        let web = await Self.page("<div id=editor contenteditable=true><p>Hello old world</p></div>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('editor'); e.focus();
        const r = document.createRange(); r.setStart(e.firstChild.firstChild, 6); r.setEnd(e.firstChild.firstChild, 9);
        getSelection().removeAllRanges(); getSelection().addRange(r); true
        """)
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("document.getElementById('editor').innerHTML = '<p>Changed old world</p>'; true")
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('new')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "changed")
        #expect(try await web.evaluateJavaScript("document.getElementById('editor').textContent") as? String == "Changed old world")
    }

}
