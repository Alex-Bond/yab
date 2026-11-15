import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor
struct FindTests {
    private struct Unready: Error {}

    private func load(_ web: WKWebView) async throws {
        web.loadHTMLString(Self.fixture, baseURL: URL(string: "https://find.example.test/"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('fixture-ready')")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Unready()
    }

    private func load(_ page: any PageHandle) async throws {
        page.navigate(html: Self.fixture, base: URL(string: "https://find.example.test/"))
        for _ in 0..<200 {
            if (try? await page.fixtureExpression("document.readyState === 'complete' && !!document.getElementById('fixture-ready')")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Unready()
    }

    private func page() async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.inactiveSchedulingPolicy = .none
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        try await load(web)
        return web
    }

    private func ask(_ web: WKWebView, _ needle: String, op: String = "find", forward: Bool = true) async throws -> [String: Any] {
        try #require(try await web.callAsyncJavaScript(Finder.script,
            arguments: ["op": op, "needle": needle, "forward": forward, "pictures": [:]],
            in: nil, contentWorld: Web.world) as? [String: Any])
    }

    private func inspect(_ web: WKWebView, _ script: String) async throws -> Any? {
        try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: Web.world)
    }

    private func ask(_ page: any PageHandle, _ needle: String, op: String = "find", forward: Bool = true) async throws -> [String: Any] {
        try #require(try await page.fixtureFunction(Finder.script,
            arguments: ["op": op, "needle": needle, "forward": forward, "pictures": [:]], world: .yab) as? [String: Any])
    }

    private func inspect(_ page: any PageHandle, _ script: String) async throws -> Any? {
        try await page.fixtureFunction(script, world: .yab)
    }

    @Test func findsDriveRowLabelsAndTitlesWithoutNativeFind() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        for name in ["Label Only.pdf", "Title Only.pdf", "Cell Title.pdf", "Résumé Plan.pdf"] {
            let answer = try await ask(web, name)
            #expect(answer["fallback"] == nil)
            #expect(answer["total"] as? Int == 1, "Expected one match for \(name)")
            #expect(answer["index"] as? Int == 0)
            #expect(try await inspect(web, "return window.__yabFind.layer.children.length") as? Int == 1)
        }
        #expect(try await ask(web, "resume   plan.pdf")["total"] as? Int == 1)
        #expect(try await ask(web, "Hidden Name.pdf")["total"] as? Int == 0)
        #expect(try await ask(web, "Outside Label.pdf")["total"] as? Int == 0)
    }

    @Test func repeatedAttributesDoNotInflateVisibleTextCounts() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        #expect(try await ask(web, "Shared File.pdf")["total"] as? Int == 2)
        #expect(try await inspect(web, "return CSS.highlights.get('yab-find').size") as? Int == 2)
        #expect(try await ask(web, "Label Only.pdf")["total"] as? Int == 1)
        #expect(try await ask(web, "echo")["total"] as? Int == 2)
    }

    @Test func openShadowTextAndBoxlessParentsStayInYabsIndex() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        for name in ["Direct Shadow.pdf", "Nested Shadow.pdf", "Shadow Label.pdf", "Contents File.pdf", "Clipped File.pdf", "Offscreen File.pdf"] {
            let answer = try await ask(web, name, op: "recount")
            #expect(answer["fallback"] == nil)
            #expect(answer["total"] as? Int == 1, "Expected one match for \(name)")
        }
        #expect(try await ask(web, "Hidden Shadow.pdf")["total"] as? Int == 0)
        #expect(try await ask(web, "BoundaryStartBoundaryEnd")["total"] as? Int == 0)
    }

    @Test func steppingWrapsBetweenTextAndAttributeMatches() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        let first = try await ask(web, "Mixed File.pdf")
        #expect(first["total"] as? Int == 2)
        #expect(first["index"] as? Int == 0)
        #expect(try await ask(web, "Mixed File.pdf", op: "step")["index"] as? Int == 1)
        #expect(try await ask(web, "Mixed File.pdf", op: "step")["index"] as? Int == 0)
        #expect(try await ask(web, "Mixed File.pdf", op: "step", forward: false)["index"] as? Int == 1)
        _ = try await ask(web, "", op: "close")
        #expect(try await inspect(web, "return !window.__yabFind.host && !CSS.highlights.has('yab-find') && !CSS.highlights.has('yab-find-current')") as? Bool == true)
    }

    @Test func iframeAndFormValuesNeverReplaceYabsCountOrHighlights() async throws {
        let tab = Fast.Tab(bench: true)
        try await load(tab.page)
        defer { tab.finder.close(); tab.page.stopLoading(); tab.close() }
        tab.finder.open()
        tab.finder.needle = "Shared File.pdf"
        for _ in 0..<200 {
            if tab.finder.asked { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.finder.asked && !tab.finder.webKitFinds && !tab.finder.missed)
        #expect(tab.finder.total == 2)
        #expect(try await inspect(tab.page, "return CSS.highlights.get('yab-find').size") as? Int == 2)
        tab.finder.needle = "Not Mounted.pdf"
        for _ in 0..<200 {
            if tab.finder.missed { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(tab.finder.asked && tab.finder.missed && !tab.finder.webKitFinds && tab.finder.total == 0)
        for name in ["Frame Only.pdf", "Input Only.pdf", "Not Mounted.pdf"] {
            let answer = try await ask(tab.page, name)
            #expect(answer["fallback"] == nil)
            #expect(answer["total"] as? Int == 0)
        }
    }

    @Test func ordinaryMatchingStillFoldsAccentsAndKeepsBlockBoundaries() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        #expect(try await ask(web, "cafe   plan")["total"] as? Int == 1)
        #expect(try await ask(web, "one block another block")["total"] as? Int == 0)
        let miss = try await ask(web, "Absent File.pdf")
        #expect(miss["fallback"] == nil && miss["total"] as? Int == 0)
        let blank = try await ask(web, "   ")
        #expect(blank["total"] as? Int == 0 && blank["index"] as? Int == -1)
    }

    @Test func shadowMutationsAndNewlyMountedRowsInvalidateTheIndex() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        #expect(try await ask(web, "Mutable File.pdf")["total"] as? Int == 1)
        _ = try await web.evaluateJavaScript("document.getElementById('shadow').shadowRoot.getElementById('mutable').firstChild.data += ' Mutable File.pdf'; true")
        #expect(try await ask(web, "Mutable File.pdf", op: "recount")["total"] as? Int == 2)
        _ = try await web.evaluateJavaScript("""
        (() => {
          const row = document.createElement('div');
          row.setAttribute('role', 'row'); row.setAttribute('aria-label', 'Mounted File.pdf');
          row.textContent = 'Mounted metadata'; document.body.append(row);
          const host = document.createElement('div');
          host.attachShadow({mode:'open'}).textContent = 'Mounted Shadow.pdf'; document.body.append(host);
          return true;
        })()
        """)
        #expect(try await ask(web, "Mounted File.pdf", op: "recount")["total"] as? Int == 1)
        #expect(try await ask(web, "Mounted Shadow.pdf", op: "recount")["total"] as? Int == 1)
        _ = try await ask(web, "Mounted Shadow.pdf", op: "pause")
        _ = try await ask(web, "Mutable File.pdf", op: "recount")
        _ = try await web.evaluateJavaScript("document.getElementById('shadow').shadowRoot.getElementById('mutable').textContent = 'Changed File.pdf'; true")
        #expect(try await ask(web, "Changed File.pdf", op: "recount")["total"] as? Int == 1)
        _ = try await ask(web, "", op: "close")
        #expect(try await inspect(web, "return window.__yabFind.observer === null && window.__yabFind.index === null && !window.__yabFind.timer") as? Bool == true)
    }

    @Test func onlyHiddenAndOpenAttributesInvalidateAndShareAThrottledRecount() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        _ = try await ask(web, "Hidden Name.pdf")
        _ = try await inspect(web, "window.savedIndex = window.__yabFind.index; window.__yabFind.cost = 1000; return true")
        _ = try await web.evaluateJavaScript("""
        (() => {
          const row = document.getElementById('label-row');
          row.className = 'animated'; row.style.opacity = '0.9'; row.setAttribute('slot', 'changed');
          return true;
        })()
        """)
        #expect(try await inspect(web, "return !window.__yabFind.dirty && !window.__yabFind.timer && window.savedIndex === window.__yabFind.index") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.getElementById('hidden-row').hidden = false; true")
        #expect(try await inspect(web, "window.savedTimer = window.__yabFind.timer; return window.__yabFind.dirty && !!window.savedTimer") as? Bool == true)
        _ = try await web.evaluateJavaScript("document.getElementById('details').open = true; true")
        #expect(try await inspect(web, "return window.__yabFind.timer === window.savedTimer") as? Bool == true)
        #expect(try await ask(web, "Hidden Name.pdf", op: "recount")["total"] as? Int == 1)
        #expect(try await ask(web, "Opened File.pdf", op: "recount")["total"] as? Int == 1)
        _ = try await web.evaluateJavaScript("document.getElementById('details').open = false; document.getElementById('hidden-row').hidden = true; true")
        #expect(try await ask(web, "Hidden Name.pdf", op: "recount")["total"] as? Int == 0)
        #expect(try await ask(web, "Opened File.pdf", op: "recount")["total"] as? Int == 0)
        _ = try await ask(web, "", op: "close")
    }

    @Test func labelVisibilityChecksStayInsideTheSlicedWalk() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        _ = try await web.evaluateJavaScript("""
        const rows = document.createDocumentFragment();
        for (let i = 0; i < 2048; i++) {
          const row = document.createElement('div'); row.setAttribute('role', 'row');
          row.setAttribute('aria-label', 'Sliced File.pdf'); row.textContent = 'Metadata'; rows.append(row);
        }
        document.body.append(rows); true
        """)
        _ = try await inspect(web, """
        window.sliceReads = []; window.visibilityReads = 0;
        const visible = Element.prototype.checkVisibility;
        Element.prototype.checkVisibility = function(options) { window.visibilityReads++; return visible.call(this, options); };
        const channel = window.MessageChannel;
        window.MessageChannel = function() { window.sliceReads.push(window.visibilityReads); return new channel(); };
        let clock = 0; performance.now = () => ++clock * 7;
        return true;
        """)
        #expect(try await ask(web, "Sliced File.pdf")["total"] as? Int == 2048)
        #expect(try await inspect(web, "return window.sliceReads.length > 2 && window.sliceReads[0] < 256 && window.visibilityReads > 2048") as? Bool == true)
        _ = try await ask(web, "", op: "close")
    }

    @Test func closedDetailsKeepOnlyTheirFirstSummarySearchable() async throws {
        let web = try await page()
        defer { web.stopLoading() }
        let hidden = ["Opened File.pdf", "Direct Details.pdf", "Boxless Details.pdf", "Details Label.pdf",
                      "Extra Summary.pdf", "Nested Details.pdf", "Details Shadow.pdf"]
        #expect(try await ask(web, "Details Summary.pdf", op: "recount")["total"] as? Int == 1)
        for name in hidden {
            #expect(try await ask(web, name, op: "recount")["total"] as? Int == 0, "Expected no closed-details match for \(name)")
        }
        _ = try await web.evaluateJavaScript("document.getElementById('details').open = true; true")
        for name in hidden {
            #expect(try await ask(web, name, op: "recount")["total"] as? Int == 1, "Expected one open-details match for \(name)")
        }
        _ = try await web.evaluateJavaScript("document.getElementById('details').open = false; true")
        #expect(try await ask(web, "Details Summary.pdf", op: "recount")["total"] as? Int == 1)
        for name in hidden {
            #expect(try await ask(web, name, op: "recount")["total"] as? Int == 0, "Expected no closed-details match for \(name)")
        }
        _ = try await ask(web, "", op: "close")
    }

    private static let fixture = """
    <!doctype html><meta charset="utf-8"><body>
    <div role="grid">
      <div id="label-row" role="row" aria-label="Label Only.pdf" title="Label Only.pdf">Metadata</div>
      <div role="row" title="Title Only.pdf">Metadata</div>
      <div role="row"><div role="gridcell" title="Cell Title.pdf">Metadata</div></div>
      <div role="row" aria-label="Résumé Plan.pdf">Metadata</div>
      <div role="row" aria-label="Shared File.pdf" title="Shared File.pdf"><span>Shared File.pdf</span></div>
      <div role="row"><span>Shared File.pdf</span></div>
      <div role="row" aria-label="Mixed File.pdf">Metadata</div><div>Mixed File.pdf</div>
      <div role="row" aria-label="echo"><span>echo echo</span></div>
      <div id="hidden-row" role="row" hidden aria-label="Hidden Name.pdf">Metadata</div>
      <div role="row"><span style="display:contents">Contents File.pdf</span></div>
      <div style="width:30px;overflow:hidden;white-space:nowrap">Clipped File.pdf</div>
      <div style="position:absolute;top:2000px">Offscreen File.pdf</div>
    </div>
    <div aria-label="Outside Label.pdf">Outside metadata</div>
    <div role="row" aria-label="Café Plan"><span>Café <b title="Plan">Plan</b></span></div>
    <div>one block</div><div>another block</div>
    <details id="details">
      Direct Details.pdf
      <summary><span>Details Summary.pdf</span></summary><div>Opened File.pdf</div>
      <span style="display:contents">Boxless Details.pdf</span>
      <div role="row" aria-label="Details Label.pdf">Details metadata</div>
      <summary>Extra Summary.pdf</summary>
      <details open><summary>Nested Details.pdf</summary></details>
      <div id="details-shadow"></div>
    </details>
    <input value="Input Only.pdf"><input value="Shared File.pdf"><textarea>Input Only.pdf</textarea>
    <iframe srcdoc="<p>Frame Only.pdf</p><p>Shared File.pdf</p>"></iframe>
    <div id="shadow"></div><div id="hidden-shadow" hidden></div>
    <span>BoundaryStart</span><span id="boundary"></span>
    <script>
    const root = document.getElementById('shadow').attachShadow({mode:'open'});
    root.append('Direct Shadow.pdf');
    const nested = document.createElement('div'); root.append(nested);
    nested.attachShadow({mode:'open'}).textContent = 'Nested Shadow.pdf';
    const row = document.createElement('div'); row.setAttribute('role', 'row');
    row.setAttribute('aria-label', 'Shadow Label.pdf'); row.textContent = 'Shadow metadata'; root.append(row);
    const mutable = document.createElement('div'); mutable.id = 'mutable'; mutable.textContent = 'Mutable File.pdf'; root.append(mutable);
    document.getElementById('hidden-shadow').attachShadow({mode:'open'}).textContent = 'Hidden Shadow.pdf';
    document.getElementById('boundary').attachShadow({mode:'open'}).textContent = 'BoundaryEnd';
    document.getElementById('details-shadow').attachShadow({mode:'open'}).textContent = 'Details Shadow.pdf';
    const ready = document.createElement('div'); ready.id = 'fixture-ready'; document.body.append(ready);
    </script>
    """
}
