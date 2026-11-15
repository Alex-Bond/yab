import AppKit
import Testing
import WebKit
@testable import Fast

// An agent's keys: read once, then sent as key events in a window or, in a
// background tab with none, told to the page in script.
struct AgentKeysTests {
    static func read(_ keys: String) -> [AgentPage.Stroke] {
        (try? AgentPage.strokes(keys).get()) ?? []
    }

    @Test func namedKeys() {
        let enter = Self.read("Enter")
        #expect(enter.count == 1)
        #expect(enter[0].key == "Enter" && enter[0].keyCode == 13 && enter[0].code == 36 && enter[0].text.isEmpty)
        let walk = Self.read("ArrowDown ArrowDown Tab")
        #expect(walk.map(\.key) == ["ArrowDown", "ArrowDown", "Tab"])
    }

    @Test func chords() {
        let all = Self.read("Meta+a")
        #expect(all.count == 1)
        #expect(all[0].command && all[0].key == "a" && all[0].domCode == "KeyA" && all[0].keyCode == 65)
        // A chord types nothing.
        #expect(all[0].text.isEmpty)
        let send = Self.read("Cmd+Enter")
        #expect(send[0].command && send[0].key == "Enter")
        let shifted = Self.read("Shift+b")
        #expect(shifted[0].shift && shifted[0].key == "B" && shifted[0].text == "B")
        #expect(Self.read("Meta++")[0].key == "+")
    }

    @Test func wordsKeyByKey() {
        let word = Self.read("hi5")
        #expect(word.map(\.key) == ["h", "i", "5"])
        #expect(word.map(\.text) == ["h", "i", "5"])
        #expect(word[2].domCode == "Digit5" && word[2].keyCode == 53)
        #expect(Self.read("space")[0].text == " ")
    }

    @Test func troubles() {
        #expect(AgentPage.strokes("Hyper+a") == .failure(AgentPage.KeyTrouble("unknown modifier Hyper")))
        #expect(AgentPage.strokes("Meta+Launch") == .failure(AgentPage.KeyTrouble("unknown key Launch")))
    }

    // MARK: - in a page with no window

    @MainActor
    final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    @MainActor
    static func page(_ html: String) async -> PageView {
        let web = PageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        await withCheckedContinuation { go in
            loaded.done = go
            web.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        }
        _ = loaded
        return web
    }

    @MainActor
    static func eval(_ web: WKWebView, _ script: String) async -> Any? {
        try? await web.callAsyncJavaScript(script, contentWorld: .page)
    }

    @MainActor
    static func settle(_ web: WKWebView) async {
        // The keys run in one call; a round trip after it has them done.
        _ = await eval(web, "return 1")
    }

    @Test @MainActor func typesAndSubmitsWithoutAWindow() async {
        let web = await Self.page("""
        <form id=f onsubmit="event.preventDefault(); document.body.dataset.sent = document.getElementById('q').value">
          <input id=q><button type=submit>Go</button>
        </form>
        <script>
          document.getElementById('q').addEventListener('keydown', e => { document.body.dataset.downs = (+document.body.dataset.downs || 0) + 1 });
        </script>
        """)
        #expect(web.window == nil)
        _ = await Self.eval(web, "document.getElementById('q').focus(); return 1")
        #expect(AgentPage.press(web, "cat") == nil)
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.getElementById('q').value") as? String == "cat")
        #expect(await Self.eval(web, "return document.body.dataset.downs") as? String == "3")
        #expect(AgentPage.press(web, "Backspace Enter") == nil)
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.body.dataset.sent") as? String == "ca")
    }

    @Test @MainActor func aPageThatTakesTheKeyKeepsIt() async {
        let web = await Self.page("""
        <div id=box contenteditable></div>
        <script>
          const box = document.getElementById('box');
          box.addEventListener('keydown', e => { if (e.key === 'Enter' && e.metaKey) { e.preventDefault(); document.body.dataset.sent = box.innerText } });
        </script>
        """)
        _ = await Self.eval(web, "document.getElementById('box').focus(); return 1")
        #expect(AgentPage.press(web, "hi Meta+Enter") == nil)
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.body.dataset.sent") as? String == "hi")
    }

    // Draft (X's reply box) puts a keyboard's text in itself from
    // textInput; the browser's own insertion beside it gave the words twice.
    @Test @MainActor func anEditorThatInsertsItselfGetsTheWordsOnce() async {
        let web = await Self.page("""
        <div id=box contenteditable></div>
        <script>
          const box = document.getElementById('box');
          box.addEventListener('textInput', e => { e.preventDefault(); box.textContent += e.data });
        </script>
        """)
        _ = await Self.eval(web, "document.getElementById('box').focus(); return 1")
        AgentPage.insert(web, "congrats")
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.getElementById('box').textContent") as? String == "congrats")
        #expect(AgentPage.press(web, "hi") == nil)
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.getElementById('box').textContent") as? String == "congratshi")
        // A box no editor runs: WebKit's own insertion, once.
        _ = await Self.eval(web, "const p = document.createElement('div'); p.id = 'plain'; p.contentEditable = 'true'; document.body.append(p); p.focus(); return 1")
        AgentPage.insert(web, "cat")
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.getElementById('plain').textContent") as? String == "cat")
    }

    @Test @MainActor func tabMovesTheFocus() async {
        let web = await Self.page("<input id=a><input id=b>")
        _ = await Self.eval(web, "document.getElementById('a').focus(); return 1")
        #expect(AgentPage.press(web, "Tab") == nil)
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.activeElement.id") as? String == "b")
        AgentPage.insert(web, "words")
        await Self.settle(web)
        #expect(await Self.eval(web, "return document.getElementById('b').value") as? String == "words")
    }
}
