import AppKit
import Testing
import WebKit
@testable import Fast

/// Crash #8 (0.0.8): WebKit files a page's edits in its view's undoManager
/// with a target that dies with the view, and takes them out on close
/// through that same undoManager. A tab closed while not in front had no
/// window, so its edits stayed in the window's undo, and ⌘Z on another page
/// sent undoEditing: to freed memory. A PageView keeps its edits itself.
@Suite(.serialized)
@MainActor
struct PageUndoTests {
    @Test func aPagesTypingStaysOutOfTheWindowsUndo() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        window.contentView?.addSubview(web)
        #expect(web.undoManager != nil)
        #expect(web.undoManager !== window.undoManager)

        web.loadHTMLString("<div id=f contenteditable>x</div>", baseURL: URL(string: "https://undo.example.test/"))
        var loaded = false
        for _ in 0..<200 where !loaded {
            loaded = (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('f')")) as? Bool == true
            if !loaded { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(loaded)
        // Typed as the page's own editing does: WebKit files it for undo.
        let typed = try await web.evaluateJavaScript("""
            (() => { const f = document.getElementById('f'); f.focus();
              getSelection().selectAllChildren(f); getSelection().collapseToEnd();
              return document.execCommand('insertText', false, 'typed') ? f.textContent : 'refused' })()
            """)
        #expect(typed as? String == "xtyped")
        // WebKit files the edit from the page's process, a moment later.
        for _ in 0..<100 where web.undoManager?.canUndo != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(web.undoManager?.canUndo == true)
        #expect(window.undoManager?.canUndo != true)

        web.removeFromSuperview()
        #expect(window.undoManager?.canUndo != true)
        window.close()
    }

    /// The window's own undo, which ⌘Z on a page must leave alone.
    final class Kept: NSObject {
        var undone = 0
        @objc func back(_ any: Any?) { undone += 1 }
    }

    /// 0.0.9: the Edit menu's undo: goes up to the window, which undid in
    /// its own manager and never asked the page's: ⌘Z left the page's typing
    /// and undid whatever the window held, a closed reply's keys on freed
    /// words. With the page in front, ⌘Z undoes the page and only the page.
    @Test func commandZOnAPageUndoesThePageOnly() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        window.contentView?.addSubview(web)
        #expect(window.makeFirstResponder(web))
        let kept = Kept()
        window.undoManager?.registerUndo(withTarget: kept, selector: #selector(Kept.back(_:)), object: nil)

        web.loadHTMLString("<div id=f contenteditable>x</div>", baseURL: URL(string: "https://undo.example.test/"))
        var loaded = false
        for _ in 0..<200 where !loaded {
            loaded = (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('f')")) as? Bool == true
            if !loaded { try await Task.sleep(for: .milliseconds(25)) }
        }
        #expect(loaded)
        let typed = try await web.evaluateJavaScript("""
            (() => { const f = document.getElementById('f'); f.focus();
              getSelection().selectAllChildren(f); getSelection().collapseToEnd();
              return document.execCommand('insertText', false, 'typed') ? f.textContent : 'refused' })()
            """)
        #expect(typed as? String == "xtyped")
        for _ in 0..<100 where web.undoManager?.canUndo != true {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(window.undoManager?.canUndo == true)

        // ⌘Z as the Edit menu sends it: undo: up the chain from the page.
        let item = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        #expect(web.tryToPerform(Selector(("undo:")), with: item))
        var text = "xtyped"
        for _ in 0..<100 where text != "x" {
            text = (try? await web.evaluateJavaScript("document.getElementById('f').textContent")) as? String ?? ""
            if text != "x" { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(text == "x")
        #expect(kept.undone == 0)
        #expect(window.undoManager?.canUndo == true)
        withExtendedLifetime(kept) {}
    }
}
