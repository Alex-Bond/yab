import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct LinkCardTests {
    /// A successful old-document answer can be delivered after didCommit,
    /// even though no anchor has yet been accepted and no card exists.
    @Test func aCommitRejectsOldDocumentCallbacksAndAcceptsNewOnes() {
        var queries = LinkCardQueries()
        let source = UUID()
        var accepted: [String] = []
        let old = queries.begin(for: source)
        let deliverOld = {
            if queries.accepts(old) { accepted.append("old document") }
        }
        #expect(queries.accepts(old))
        let cancelledSource = queries.cancel(for: source)
        #expect(cancelledSource)
        deliverOld()
        #expect(accepted.isEmpty)

        // The tab identity and URL may be unchanged by a reload. A new
        // request still needs a different ticket, not an activeID check.
        let fresh = queries.begin(for: source)
        if queries.accepts(fresh) { accepted.append("new document") }
        deliverOld()
        #expect(accepted == ["new document"])
    }

    @Test func aCommitCancelsQueuedReadsButPreservesAnotherTabsRead() {
        var queries = LinkCardQueries()
        let source = UUID(), other = UUID()
        let queued = queries.begin(for: source)
        var dispatched = 0
        let dispatch = {
            if queries.accepts(queued) { dispatched += 1 }
        }
        let cancelledOther = queries.cancel(for: other)
        #expect(!cancelledOther)
        #expect(queries.accepts(queued))
        let cancelledSource = queries.cancel(for: source)
        #expect(cancelledSource)
        dispatch()
        #expect(dispatched == 0)
        let fresh = queries.begin(for: source)
        #expect(queries.accepts(fresh))
        #expect(!queries.accepts(queued))
    }

    @Test func aCardNeedsRestAndNeverOverridesSelectionOrOtherModifiers() {
        #expect(LinkCardRules.dwell > 0.4)
        #expect(LinkCardRules.highlight < LinkCardRules.dwell)
        #expect(!LinkCardRules.eligible(flags: [], selection: false))
        #expect(LinkCardRules.eligible(flags: .shift, selection: false))
        let all: [NSEvent.ModifierFlags] = [.shift, [], .command, [.command, .shift], .option, .control]
        for flags in all {
            #expect(!LinkCardRules.eligible(flags: flags, selection: true))
        }
        let other: [NSEvent.ModifierFlags] = [.command, [.command, .shift], .option, .control]
        for flags in other {
            #expect(!LinkCardRules.eligible(flags: flags, selection: false))
        }
    }

    @Test func onlyOrdinaryWebURLsArePreloaded() {
        for address in ["https://example.org/news", "http://127.0.0.1:8765/story"] {
            #expect(LinkCardRules.web(URL(string: address)!))
        }
        for address in ["javascript:alert(1)", "file:///tmp/page.html", "mailto:a@b.com", "yab://settings", "https://user:secret@example.org/"] {
            #expect(!LinkCardRules.web(URL(string: address)!))
        }
    }

    @Test func placementUsesTheScreenAndCanHangPastTheBrowser() {
        let screen = CGRect(x: -1200, y: 100, width: 1200, height: 800)
        let size = CGSize(width: 296, height: 220)
        let link = CGRect(x: -900, y: 700, width: 160, height: 20)
        let below = LinkCardRules.place(link: link, size: size, screen: screen)
        #expect(below.minX == link.minX - 5)
        #expect(below.maxY == link.minY - 7)
        let low = CGRect(x: -400, y: 160, width: 130, height: 20)
        #expect(LinkCardRules.place(link: low, size: size, screen: screen).minY == low.maxY + 7)
        let right = LinkCardRules.place(link: CGRect(x: -20, y: 600, width: 60, height: 20), size: size, screen: screen)
        #expect(right.maxX == screen.maxX - 8)
        let huge = LinkCardRules.place(link: link, size: CGSize(width: 5000, height: 5000), screen: screen)
        #expect(screen.insetBy(dx: 8, dy: 8).contains(huge))
    }

    /// A connected AI's reply: JSON, perhaps inside words or a fence,
    /// held to the card's limits and its icons.
    @Test func aConnectedAIsReplyBecomesABoundedPreview() {
        let reply = """
        Sure:
        ```json
        {"summary": "A starter guide for sourdough bakers who want tangy bread", "facts": [
          {"label": "Feeding:", "icon": "time", "text": "Every day with equal weights of flour and water"},
          {"label": "Storage", "icon": "rocket", "text": "Covered, refrigerated between bakes"},
          {"label": "", "icon": "detail", "text": "dropped"},
          {"label": "Taste", "icon": "feature", "text": "Tangy"},
          {"label": "Extra", "icon": "detail", "text": "a fourth"}]}
        ```
        """
        let preview = LinkSummary.parse(reply)
        #expect(preview?.summary == "A starter guide for sourdough bakers who want")
        #expect(preview?.facts.map(\.label) == ["Feeding", "Storage", "Taste"])
        #expect(preview?.facts.map(\.icon) == ["clock", "doc.text", "star"])
        #expect(LinkSummary.parse("I can't help with that.") == nil)
        // As the Mac's model writes it: nearly JSON, a trailing comma, cut short.
        let nearly = LinkSummary.parse(#"{"summary": "Interface Club acquired by \"Variant\"", "facts": [{"label": "time", "icon": "time", "text": "Iris and Buoy sunset November 15"}, {"label": "Who", "icon": "person", "text": "Variant"},], "#)
        #expect(nearly?.summary == "Interface Club acquired by \"Variant\"")
        #expect(nearly?.facts.map(\.text) == ["Iris and Buoy sunset November 15", "Variant"])
        #expect(nearly?.facts.first?.icon == "clock")
        #expect(LinkSummary.parse(#"{"summary": "", "facts": []}"#) == nil)
    }

    @Test func pageMetadataIncludesTheImageAndGeneratedWordsStayBounded() {
        let page = LinkSummary.read("""
        <title>Original</title><meta property="og:title" content="Bread &amp; butter">
        <meta content="/cover.png" property="og:image"><meta name="description" content="A starter guide.">
        <script>ignore this</script><p>Flour and water.</p>
        """)
        #expect(page.title == "Bread & butter")
        #expect(page.image == "/cover.png")
        #expect(page.description == "A starter guide.")
        #expect(!page.text.contains("ignore this"))
        #expect(LinkSummary.Preview.words(" One  two\nthree four five six seven eight nine ", limit: 8) == "One two three four five six seven eight")
    }

    /// The document's hit test stops at a shadow host; Peek and cards must
    /// find the same nested anchor and keep its real origin.
    @Test func nestedShadowLinksSharePeekOriginAndHoverHighlight() async throws {
        let view = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let web: any PageHandle = view
        defer { view.stopLoading() }
        web.navigate(html: "<div id=host style='position:fixed;left:100px;top:100px;width:240px;height:100px'></div>",
                     base: URL(string: "https://fixture.example/"))
        for _ in 0..<100 {
            if (try? await web.run("!!document.querySelector('#host')", in: .yab)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.run(PeekOrigin.script(force: true), in: .yab)
        _ = try await web.run(LinkCardRules.script, in: .yab)
        _ = try await web.run("""
        const root = document.querySelector('#host').attachShadow({mode:'open'});
        root.innerHTML = '<div id=inner style="width:240px;height:100px"></div>';
        root.querySelector('#inner').attachShadow({mode:'open'}).innerHTML = '<a href="/article" target="_blank" style="display:block;width:240px;height:100px"><b>Article</b></a>';
        """, in: .yab)
        let card = try await web.run("__yabLinkCardInfo(160,140,innerWidth,'')", in: .yab) as? [String: Any]
        #expect(card?["url"] as? String == "https://fixture.example/article")
        _ = try await web.run("__yabLinkCardLightAt(160,140,true)", in: .yab)
        #expect(try await web.run("document.querySelectorAll('[aria-hidden=true]').length", in: .yab) as? Int == 1)
        _ = try await web.run("__yabLinkCardLightAt(160,140,false)", in: .yab)
        #expect(try await web.run("document.querySelectorAll('[aria-hidden=true]').length", in: .yab) as? Int == 0)
        _ = try await web.run("""
        const a = document.querySelector('#host').shadowRoot.querySelector('#inner').shadowRoot.querySelector('a');
        a.querySelector('b').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true,composed:true,altKey:true,button:0}));
        """, in: .yab)
        let origin = try await web.run("__yabPeekFrom(true)", in: .yab) as? [NSNumber]
        #expect(origin?.count == 6)
        #expect(origin?.first?.doubleValue == 100)
        #expect(try await web.run("__yabPeekForce(160,140,innerWidth)", in: .yab) as? String == "https://fixture.example/article")
    }

    /// Real DOM hit testing: Shift must yield to an existing range.
    @Test func selectionIsCheckedOnTheActualAnchor() async throws {
        let view = PageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: WKWebViewConfiguration())
        let web: any PageHandle = view
        web.navigate(html: """
        <style>body{margin:0}a{display:block;width:300px;height:50px}</style>
        <div class="titleline"><a href="https://example.org/story">Story</a></div>
        <a href="https://example.org/account">Account</a><p id="text">Some ordinary text</p>
        """, base: URL(string: "https://news.ycombinator.com/"))
        for _ in 0..<100 {
            if (try? await web.run("document.querySelectorAll('a').length", in: .yab)) as? Int == 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.run(LinkCardRules.script, in: .yab)
        let one = try await web.run("__yabLinkCardInfo(20,20,800,'')", in: .yab) as? [String: Any]
        #expect(one?["url"] as? String == "https://example.org/story")
        _ = try await web.run("document.querySelector('a').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));getSelection().collapse(document.querySelector('a').firstChild,1)", in: .yab)
        let linkCaret = try await web.run("__yabLinkCardInfo(20,20,800,'')", in: .yab) as? [String: Any]
        #expect(linkCaret?["selection"] as? Bool == false)
        _ = try await web.run("getSelection().collapse(document.querySelector('#text').firstChild,1)", in: .yab)
        let textCaret = try await web.run("__yabLinkCardInfo(20,20,800,'')", in: .yab) as? [String: Any]
        #expect(textCaret?["selection"] as? Bool == true)
        _ = try await web.run("const s=getSelection(),r=document.createRange();r.selectNodeContents(document.querySelector('#text'));s.removeAllRanges();s.addRange(r)", in: .yab)
        let selected = try await web.run("__yabLinkCardInfo(20,20,800,'')", in: .yab) as? [String: Any]
        #expect(selected?["selection"] as? Bool == true)
        _ = try await web.run("getSelection().removeAllRanges();__yabLinkCardLightAt(20,20,true);__yabLinkCardLightAt(20,20,false)", in: .yab)
        #expect(try await web.run("document.querySelectorAll('[aria-hidden=true]').length", in: .yab) as? Int == 0)
    }
}
