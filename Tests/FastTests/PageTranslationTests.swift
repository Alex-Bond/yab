import AppKit
import SwiftUI
import Testing
import Translation
import WebKit
@testable import Fast

struct PageTranslationTests {
    @MainActor final class BodyCounter { var count = 0 }
    private struct Parent: View {
        let translation: PageTranslation
        let counter: BodyCounter
        var body: some View {
            counter.count += 1
            return PageTranslationHost(translation: translation)
        }
    }

    @MainActor
    private static func page(_ html: String) async throws -> WKWebView {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        web.loadHTMLString(html, baseURL: URL(string: "https://example.test/article"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.readyState === 'complete' && document.querySelector('h1') != null")) as? Bool == true { return web }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw CocoaError(.fileReadUnknown)
    }

    @MainActor
    private static func inYab(_ web: WKWebView, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            web.evaluateInYab(script) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private static func inPage(_ page: any PageHandle, _ script: String) async -> Any? {
        await withCheckedContinuation { continuation in
            page.runInYab(script) { continuation.resume(returning: $0) }
        }
    }

    @MainActor
    private static func collect(_ web: WKWebView) async throws -> [[String: String]] {
        let result = await inYab(web, PageTranslation.collectScript)
        let data = try #require(result as? [String: Any])
        return try #require(data["items"] as? [[String: String]])
    }

    @MainActor
    private static func collect(_ page: any PageHandle) async throws -> [[String: String]] {
        let result = await inPage(page, PageTranslation.collectScript)
        let data = try #require(result as? [String: Any])
        return try #require(data["items"] as? [[String: String]])
    }

    @MainActor
    private static func apply(_ values: [[String: String]], to web: WKWebView) async throws {
        let data = try JSONSerialization.data(withJSONObject: values)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(await inYab(web, "window.__yabPageTranslation.apply(\(json)); true") as? Bool == true)
    }

    @Test @MainActor func translatesVisibleTextAndControlsThenRestores() async throws {
        let web = try await Self.page("""
        <html lang="en"><body><h1>  Hello world  </h1><p>Read <strong>every</strong> page.</p>
        <input id="query" placeholder="Search pages" value="Private draft"><input type="submit" value="Subscribe">
        <code>let x = 'Hello'</code><div contenteditable="true">User draft</div>
        <span hidden>Hidden words</span><span style="display:none">CSS hidden</span>
        <span translate="no">Brand name</span></body></html>
        """)
        let items = try await Self.collect(web)
        let strings = items.compactMap { $0["text"] }
        #expect(strings.contains("Hello world"))
        #expect(strings.contains("Search pages"))
        #expect(strings.contains("Subscribe"))
        #expect(!strings.contains("User draft"))
        #expect(!strings.contains("Hidden words"))
        #expect(!strings.contains("CSS hidden"))
        #expect(!strings.contains("Brand name"))
        #expect(!strings.contains("let x = 'Hello'"))

        let translations = ["Hello world": "Hola, mundo", "Search pages": "Buscar páginas", "Subscribe": "Suscribirse"]
        try await Self.apply(items.compactMap { item in
            guard let id = item["id"], let source = item["text"], let translated = translations[source] else { return nil }
            return ["id": id, "text": translated]
        }, to: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "  Hola, mundo  ")
        #expect(try await web.evaluateJavaScript("document.querySelector('#query').placeholder") as? String == "Buscar páginas")
        #expect(try await web.evaluateJavaScript("document.querySelector('#query').value") as? String == "Private draft")
        #expect(try await web.evaluateJavaScript("document.querySelector('input[type=submit]').value") as? String == "Suscribirse")
        #expect(await Self.inYab(web, "window.__yabPageTranslation.restore(); true") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "  Hello world  ")
        #expect(try await web.evaluateJavaScript("document.querySelector('#query').placeholder") as? String == "Search pages")
    }

    /// Register #1103: in Reading Mode the page's body is hidden under the
    /// reader's copy of the article, and that copy is what is translated,
    /// while the reader is still coming in as well as once it is up.
    @Test @MainActor func readingModeTranslatesTheReadersCopy() async throws {
        let prose = (1...6).map { "<p>Paragraph \($0) of the article says something worth reading about distant galaxies and their light.</p>" }.joined()
        let web = try await Self.page("<html lang=\"en\"><body><nav><a href=\"/\">Home menu</a></nav><article><h1>Distant light</h1>\(prose)</article></body></html>")
        #expect(await Self.inYab(web, Reader.enter) as? String == "read")
        for moment in ["entering", "reading"] {
            if moment == "reading" { try await Task.sleep(for: .milliseconds(900)) }
            let items = try await Self.collect(web)
            let strings = items.compactMap { $0["text"] }
            #expect(strings.contains("Distant light"), "\(moment)")
            #expect(strings.contains { $0.hasPrefix("Paragraph 6") }, "\(moment)")
            #expect(!strings.contains("Home menu"), "\(moment)")
            let title = try #require(items.first { $0["text"] == "Distant light" }?["id"])
            try await Self.apply([["id": title, "text": "Luz lejana"]], to: web)
            #expect(try await web.evaluateJavaScript("document.querySelector('#yab-reader h1').textContent") as? String == "Luz lejana", "\(moment)")
            #expect(try await web.evaluateJavaScript("document.querySelector('article h1').textContent") as? String == "Distant light", "\(moment)")
            #expect(await Self.inYab(web, "window.__yabPageTranslation.restore(); true") as? Bool == true)
            #expect(try await web.evaluateJavaScript("document.querySelector('#yab-reader h1').textContent") as? String == "Distant light", "\(moment)")
        }
    }

    @Test @MainActor func leavesSiteChangesAloneOnApplyAndRestore() async throws {
        let web = try await Self.page("<body><h1 id=title>Hello</h1><p id=body>Original</p></body>")
        let items = try await Self.collect(web)
        let title = try #require(items.first { $0["text"] == "Hello" }?["id"])
        let body = try #require(items.first { $0["text"] == "Original" }?["id"])
        _ = try await web.evaluateJavaScript("document.querySelector('#title').textContent = 'Changed by site'")
        try await Self.apply([["id": title, "text": "Traducción"], ["id": body, "text": "Traducido"]], to: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#title').textContent") as? String == "Changed by site")
        _ = try await web.evaluateJavaScript("document.querySelector('#body').textContent = 'Updated by site'")
        #expect(await Self.inYab(web, "window.__yabPageTranslation.restore(); true") as? Bool == true)
        #expect(try await web.evaluateJavaScript("document.querySelector('#body').textContent") as? String == "Updated by site")
    }

    @Test @MainActor func worksInIsolatedWorldAndClearsOnNewDocument() async throws {
        let web = try await Self.page("<body><h1>Hello</h1></body>")
        _ = try await Self.collect(web)
        #expect((try await web.evaluateJavaScript("typeof window.__yabPageTranslation")) as? String == "undefined")
        web.loadHTMLString("<body><h1>Second page</h1></body>", baseURL: URL(string: "https://example.test/second"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.querySelector('h1')?.textContent")) as? String == "Second page" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await Self.inYab(web, "typeof window.__yabPageTranslation") as? String == "undefined")
    }

    @Test @MainActor func contextKeepsSpacesLinksAndOriginalDOM() async throws {
        let web = try await Self.page("""
        <body><h1>Context</h1><p id=good>Read <a href="/terms">every</a> page.</p>
        <p id=spaces><span>Hello</span> <em>world</em></p>
        <p>Keep <code>privateCode</code> unchanged.</p>
        <p>Ignore <span style="display:none">hidden</span> text.</p></body>
        """)
        let original = try await web.evaluateJavaScript("document.querySelector('#good').innerHTML") as? String
        _ = try await web.evaluateJavaScript("window.link = document.querySelector('a'); link.addEventListener('click', event => { event.preventDefault(); window.clicked = true; })")
        let data = try #require(await Self.inYab(web, PageTranslation.collectScript) as? [String: Any])
        let groups = try #require(data["groups"] as? [[String: Any]])
        let texts = groups.map { ($0["parts"] as? [[String: String]] ?? []).compactMap { $0["text"] }.joined() }
        #expect(texts == ["Read every page.", "Hello world"])
        let group = try #require(groups.first)
        let parts = try #require(group["parts"] as? [[String: String]])
        let id = try #require(group["id"] as? String)
        try await Self.apply(zip(parts, ["Lee ", "cada", " página."]).map { part, text in
            ["id": part["id"]!, "text": text, "exact": "true", "group": id]
        }, to: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#good').textContent") as? String == "Lee cada página.")
        #expect(try await web.evaluateJavaScript("document.querySelector('a') === window.link && link.getAttribute('href') === '/terms'") as? Bool == true)
        _ = try await web.evaluateJavaScript("link.click()")
        #expect(try await web.evaluateJavaScript("window.clicked") as? Bool == true)
        _ = await Self.inYab(web, "window.__yabPageTranslation.restore()")
        #expect(try await web.evaluateJavaScript("document.querySelector('#good').innerHTML") as? String == original)
    }

    @Test @MainActor func contextDoesNotPartiallyOverwriteSiteUpdates() async throws {
        let web = try await Self.page("<body><h1>Context</h1><p>Read <strong>every</strong> page.</p></body>")
        let data = try #require(await Self.inYab(web, PageTranslation.collectScript) as? [String: Any])
        let groups = try #require(data["groups"] as? [[String: Any]])
        let group = try #require(groups.first)
        let parts = try #require(group["parts"] as? [[String: String]])
        _ = try await web.evaluateJavaScript("document.querySelector('strong').textContent = 'updated'")
        try await Self.apply(parts.map { ["id": $0["id"]!, "text": "Traducción", "exact": "true", "group": group["id"] as! String] }, to: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('p').textContent") as? String == "Read updated page.")
    }

    @Test func contextRejectsReorderedOrMissingAlignment() throws {
        guard #available(macOS 26.4, *) else { return }
        let context = PageTranslationContext(id: "group", parts: [.init(id: "a", text: "Read "), .init(id: "b", text: "every"), .init(id: "c", text: " page.")])
        func response(_ parts: [(String?, String)]) -> TranslationSession.Response {
            var target = AttributedString("")
            for (id, text) in parts {
                var segment = AttributedString(text)
                if let id { segment[PageTranslationNode.self] = id }
                target.append(segment)
            }
            return .init(sourceLanguage: .init(identifier: "en"), targetLanguage: .init(identifier: "es"),
                         sourceAttributedText: context.request.attributedSourceText!, targetAttributedText: target)
        }
        let aligned = context.aligned(response([("a", "Lee "), ("b", "cada"), ("c", " página.")]))
        #expect(aligned?.map { $0["text"]! }.joined() == "Lee cada página.")
        #expect(context.aligned(response([("b", "Cada "), ("c", "página "), ("a", "lee.")])) == nil)
        #expect(context.aligned(response([(nil, "Lee cada página.")])) == nil)
        #expect(context.aligned(response([("a", "Lee "), ("c", "página.")])) == nil)
        let flowing = PageTranslationContext(id: "group", parts: [.init(id: "a", text: "Read ", anchored: false), .init(id: "b", text: "every"), .init(id: "c", text: " page carefully.", anchored: false)])
        let reordered = flowing.aligned(response([("c", "Con cuidado, "), ("a", "lee "), ("b", "cada "), ("c", "página.")]))
        #expect(reordered?.map { $0["text"]! } == ["Con cuidado, lee ", "cada ", "página."])
        #expect(flowing.aligned(response([("a", "Pestaña"), ("b", " "), ("c", "del navegador")])) == nil)
    }

    @Test @MainActor func nativeSessionTranslatesAndRestoresThroughObservedHost() async throws {
        let source = Locale.Language(identifier: "es")
        let target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en-US")
        guard await LanguageAvailability().status(from: source, to: target) == .installed else { return }
        let tab = Tab(bench: true)
        defer { tab.close() }
        let web = tab.page
        let original = "Esta es una página en español. Aquí hay varias frases para probar la traducción."
        let paragraph = "Ella dejó de fumar el año pasado."
        web.navigate(html:"<html lang=es><body><h1>\(original)</h1><p>Ella <strong>dejó</strong> de fumar el año pasado.</p></body></html>",
                           base: URL(string: "https://example.test/es"))
        for _ in 0..<100 {
            if (try? await web.run("document.querySelector('h1')?.textContent")) as? String == original { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(web.url?.scheme == "https")

        let translation = PageTranslation()
        let host = NSHostingView(rootView: PageTranslationHost(translation: translation).frame(width: 1, height: 1))
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        translation.toggle(tab)
        for _ in 0..<300 {
            if translation.phase(for: tab) == .translated { break }
            if case .failed = translation.phase(for: tab) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(translation.phase(for: tab) == .translated)
        let translated = try #require(try await web.run("document.querySelector('h1').textContent") as? String)
        #expect(translated != original)
        if #available(macOS 26.4, *) {
            let context = PageTranslationContext(id: "reference", parts: [
                .init(id: "before", text: "Ella ", anchored: false),
                .init(id: "marked", text: "dejó"),
                .init(id: "after", text: " de fumar el año pasado.", anchored: false)
            ])
            let session = TranslationSession(installedSource: source, target: target,
                                             preferredStrategy: translation.configuration!.preferredStrategy)
            let reference = try await session.translate(context.source)
            let actual = try await web.run("document.querySelector('p').textContent") as? String
            #expect(actual != paragraph)
            if context.aligned(reference) != nil { #expect(actual == reference.targetText) }
            #expect(try await web.run("document.querySelector('strong').textContent.trim().length > 0") as? Bool == true)
        }
        translation.toggle(tab)
        for _ in 0..<100 {
            if (try? await web.run("document.querySelector('h1').textContent")) as? String == original { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect((try await web.run("document.querySelector('h1').textContent")) as? String == original)
        #expect(try await web.run("document.querySelector('p').innerHTML") as? String == "Ella <strong>dejó</strong> de fumar el año pasado.")
        translation.forget(tab)
        #expect(translation.phases[tab.id] == nil)
    }

    @Test @MainActor func translationStateDoesNotRedrawParentWindow() async throws {
        let translation = PageTranslation()
        let counter = BodyCounter()
        let host = NSHostingView(rootView: Parent(translation: translation, counter: counter).frame(width: 20, height: 20))
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let before = counter.count
        let tab = Tab(bench: true)
        defer { tab.close() }
        for _ in 0..<5 {
            translation.toggle(tab) // An unbuilt tab reports a failure, changing observed state.
            for _ in 0..<20 {
                if case .failed = translation.phase(for: tab) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            translation.forget(tab)
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(counter.count == before)
    }

    @Test @MainActor func emptyPageFailsWithoutHoldingPageNodes() async throws {
        let tab = Tab(bench: true)
        defer { tab.close() }
        tab.page.navigate(html:"<html lang=es><body><h1 id=marker></h1><code>private data</code></body></html>",
                               base: URL(string: "https://example.test/empty"))
        for _ in 0..<100 {
            if (try? await tab.page.run("document.querySelector('#marker') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let translation = PageTranslation()
        translation.toggle(tab)
        for _ in 0..<100 {
            if case .failed = translation.phase(for: tab) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(translation.phase(for: tab) == .failed("No text to translate on this page"))
        #expect(translation.configuration == nil)
        #expect(await Self.inPage(tab.page, "window.__yabPageTranslation ? true : false") as? Bool == true)
        #expect(await Self.inPage(tab.page, "window.__yabPageTranslation?.restore(); true") as? Bool == true)
    }

    @Test @MainActor func switchingTabsRestoresAPartlyTranslatedPage() async throws {
        guard ProcessInfo.processInfo.environment["YAB_TRANSLATION_STRESS"] == "1" else { return }
        let target = Locale.Language(identifier: Locale.preferredLanguages.first ?? "en-US")
        guard await LanguageAvailability().status(from: Locale.Language(identifier: "es"), to: target) == .installed else { return }
        let first = Tab(bench: true)
        let second = Tab(bench: true)
        defer { first.close(); second.close() }
        let original = "Artículo en español para probar el cambio"
        let many = (0..<400).map { "<p>Párrafo número \($0). Esta página tiene mucho texto en español.</p>" }.joined()
        first.page.navigate(html:"<html lang=es><body><h1>\(original)</h1>\(many)</body></html>",
                                 base: URL(string: "https://example.test/first"))
        second.page.navigate(html:"<html lang=es><body><h1>Segunda página</h1></body></html>",
                                  base: URL(string: "https://example.test/second"))
        for _ in 0..<100 {
            let a = (try? await first.page.run("document.querySelector('h1')?.textContent")) as? String
            let b = (try? await second.page.run("document.querySelector('h1')?.textContent")) as? String
            if a == original && b == "Segunda página" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let translation = PageTranslation()
        let host = NSHostingView(rootView: PageTranslationHost(translation: translation).frame(width: 1, height: 1))
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        translation.toggle(first)
        var partiallyTranslated = false
        for _ in 0..<300 {
            let text = (try? await first.page.run("document.querySelector('h1')?.textContent")) as? String
            if text != nil && text != original && translation.phase(for: first) == .translating {
                partiallyTranslated = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(partiallyTranslated)
        translation.toggle(second)
        for _ in 0..<100 {
            if (try? await first.page.run("document.querySelector('h1')?.textContent")) as? String == original { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect((try await first.page.run("document.querySelector('h1')?.textContent")) as? String == original)
        #expect(translation.phase(for: first) == .original)
    }
    // BEGIN 1291 MAIN-COMPATIBLE DOM DRIVER
    private static let dynamicHTML = """
    <html lang="es"><body><h1 id="initial">Texto inicial</h1><p id="site">Texto del sitio</p>
    <button id="open" onclick="document.getElementById('slot').innerHTML=document.getElementById('template').innerHTML">Abrir diálogo</button>
    <button id="reveal" onclick="document.getElementById('sidebar').hidden=false">Mostrar panel</button>
    <aside id="sidebar" hidden><p id="lateral">Texto lateral</p></aside><div id="slot"></div>
    <template id="template"><section role="dialog"><p id="dialog">Texto del diálogo</p>
    <input id="draft" value="Private draft"><textarea id="area">Private textarea</textarea>
    <div contenteditable="true" id="editable">Private editor</div><p translate="no" id="brand">Brand words</p><code id="code">Private code</code></section></template>
    </body></html>
    """

    private static func dictionary(_ batch: [[String: String]]) -> [[String: String]] {
        let words = ["Texto inicial": "Initial text", "Texto del sitio": "Site text",
                     "Texto lateral": "Sidebar text", "Texto del diálogo": "Dialog text"]
        return batch.compactMap { row in
            guard let id = row["id"], let text = row["text"] else { return nil }
            return ["id": id, "text": words[text] ?? "Translated: " + text]
        }
    }

    @MainActor private static func eventually(attempts: Int = 120, _ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<attempts {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    /// Identical driver runs on exact BASE. Missing next() means no dynamic
    /// batch, not a thrown API error: assertions fail on untranslated text.
    /// Dictionary owns only model output, never inserted DOM or assertions.
    @Test @MainActor func dynamicDOMQueueTranslatesInsertedAndRevealedText() async throws {
        let web = try await Self.page(Self.dynamicHTML)
        let initial = try await Self.collect(web)
        try await Self.apply(Self.dictionary(initial), to: web)
        #expect(try await web.evaluateJavaScript("document.querySelector('#initial').textContent") as? String == "Initial text")
        _ = try await web.evaluateJavaScript("document.querySelector('#open').click(); document.querySelector('#reveal').click()")
        let delta = try await web.evaluate(.function("""
            const adapter = window.__yabPageTranslation;
            if (!adapter || typeof adapter.next !== 'function') return {items: []};
            return await Promise.race([adapter.next(), new Promise(resolve => setTimeout(() => resolve({items: []}), 1500))]);
            """, arguments: [:]), in: .yab, frame: nil, gesture: false) as? [String: Any]
        try await Self.apply(Self.dictionary(delta?["items"] as? [[String: String]] ?? []), to: web)
        let observed = try await web.evaluateJavaScript("({initial:document.getElementById('initial')?.textContent,dialog:document.getElementById('dialog')?.textContent,sidebar:document.getElementById('lateral')?.textContent})") as? [String: String] ?? [:]
        print("1291_DYNAMIC_DOM_STATE:" + String(data: try JSONSerialization.data(withJSONObject: observed), encoding: .utf8)!)
        #expect(try await web.evaluateJavaScript("document.querySelector('#dialog').textContent") as? String == "Dialog text")
        #expect(try await web.evaluateJavaScript("document.querySelector('#lateral').textContent") as? String == "Sidebar text")
        #expect(try await web.evaluateJavaScript("[document.getElementById('draft').value,document.getElementById('area').value,document.getElementById('editable').textContent,document.getElementById('brand').textContent,document.getElementById('code').textContent]") as? [String]
                == ["Private draft", "Private textarea", "Private editor", "Brand words", "Private code"])
        _ = try await web.evaluateJavaScript("document.querySelector('#site').textContent = 'Changed by site'")
        _ = await Self.inYab(web, "window.__yabPageTranslation.restore()")
        #expect(try await web.evaluateJavaScript("[document.getElementById('initial').textContent,document.getElementById('dialog').textContent,document.getElementById('lateral').textContent,document.getElementById('site').textContent]") as? [String]
                == ["Texto inicial", "Texto del diálogo", "Texto lateral", "Changed by site"])
    }
    // END 1291 MAIN-COMPATIBLE DOM DRIVER

    // BEGIN 1291 CANDIDATE COORDINATOR
    @MainActor private static func dynamicTab() async throws -> Fast.Tab {
        let tab = Fast.Tab(bench: true)
        tab.page.navigate(html: Self.dynamicHTML, base: URL(string: "https://example.test/dynamic"))
        #expect(try await Self.eventually {
            try await tab.page.fixtureExpression("document.querySelector('#initial')?.textContent") as? String == "Texto inicial"
        })
        return tab
    }

    @Test @MainActor func dynamicDOMTranslationWorksOnInsecureHTTPOrigin() async throws {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { web.stopLoading() }
        // Substitute data gets a real HTTP base origin, with no network,
        // local-network grant, DNS override or localhost secure exemption.
        web.loadHTMLString(Self.dynamicHTML, baseURL: URL(string: "http://translation-insecure.invalid/article"))
        try #require(try await Self.eventually {
            try await web.evaluateJavaScript("document.getElementById('initial')?.textContent") as? String == "Texto inicial"
        })
        let query = "({secure:isSecureContext,origin:location.origin,protocol:location.protocol,randomUUID:typeof crypto.randomUUID})"
        let defaultWorld = try await web.evaluateJavaScript(query) as? [String: Any] ?? [:]
        let isolated = await Self.inYab(web, query) as? [String: Any] ?? [:]
        print("1291_HTTP_WORLD_DIAGNOSTICS:" + String(data: try JSONSerialization.data(withJSONObject: ["default": defaultWorld, "yab": isolated]), encoding: .utf8)!)
        guard isolated["secure"] as? Bool == false,
              isolated["protocol"] as? String == "http:",
              isolated["origin"] as? String == "http://translation-insecure.invalid" else {
            print("1291_INSECURE_HTTP_UNRUN: substitute-data fixture did not provide the required insecure HTTP origin in the actual yab world")
            return
        }
        print("1291_INSECURE_HTTP_CONTEXT: actual yab world isSecureContext=false http://translation-insecure.invalid")
        let initial = try await Self.collect(web)
        try await Self.apply(Self.dictionary(initial), to: web)
        _ = try await web.evaluateJavaScript("document.getElementById('open').click();document.getElementById('reveal').click()")
        let delta = try await web.evaluate(.function("""
            return await Promise.race([window.__yabPageTranslation.next(),
              new Promise(resolve => setTimeout(() => resolve({items:[]}), 1500))]);
            """, arguments: [:]), in: .yab, frame: nil, gesture: false) as? [String: Any]
        try await Self.apply(Self.dictionary(delta?["items"] as? [[String: String]] ?? []), to: web)
        #expect(try await web.evaluateJavaScript("[document.getElementById('initial').textContent,document.getElementById('dialog').textContent,document.getElementById('lateral').textContent]") as? [String]
                == ["Initial text", "Dialog text", "Sidebar text"])
        _ = await Self.inYab(web, "window.__yabPageTranslation.restore()")
        #expect(try await web.evaluateJavaScript("[document.getElementById('initial').textContent,document.getElementById('dialog').textContent,document.getElementById('lateral').textContent]") as? [String]
                == ["Texto inicial", "Texto del diálogo", "Texto lateral"])
        print("1291_INSECURE_HTTP_COLLECT_DYNAMIC_RESTORE: assertions determine pass")
    }

    /// Exercises production collection, event wait, scheduling and apply;
    /// bypasses Apple models only through the internal async dependency.
    @Test @MainActor func dynamicCoordinatorTranslatesAndStopsWithoutRetranslatingItsOwnWrites() async throws {
        let tab = try await Self.dynamicTab()
        var requested: [String] = []
        let translation = PageTranslation(translator: { batch, _, _ in
            requested += batch.compactMap { $0["text"] }
            return Self.dictionary(batch)
        })
        defer { translation.forget(tab); tab.close() }
        translation.translate(tab, to: Locale.Language(identifier: "en"))
        #expect(try await Self.eventually { translation.phase(for: tab) == .translated })
        _ = try await tab.page.fixtureExpression("document.getElementById('open').click(); document.getElementById('reveal').click()")
        #expect(try await Self.eventually {
            try await tab.page.fixtureExpression("document.getElementById('dialog').textContent === 'Dialog text' && document.getElementById('lateral').textContent === 'Sidebar text'") as? Bool == true
        })
        #expect(requested.filter { $0 == "Texto inicial" }.count == 1)
        #expect(requested.filter { $0 == "Texto del diálogo" }.count == 1)
        #expect(!requested.contains("Initial text") && !requested.contains("Dialog text"))
        #expect(!requested.contains { $0.hasPrefix("Private") || $0 == "Brand words" })
        #expect(translation.configuration == nil) // No model host or download prompt.
        translation.toggle(tab) // Show Original, including the dynamic nodes.
        #expect(try await Self.eventually {
            try await tab.page.fixtureExpression("document.getElementById('initial').textContent === 'Texto inicial' && document.getElementById('dialog').textContent === 'Texto del diálogo' && document.getElementById('lateral').textContent === 'Texto lateral'") as? Bool == true
        })
        let count = requested.count
        _ = try await tab.page.fixtureExpression("document.getElementById('dialog').textContent = 'Texto posterior'")
        try await Task.sleep(for: .milliseconds(100))
        #expect(requested.count == count)
        #expect(try await tab.page.fixtureExpression("document.getElementById('dialog').textContent") as? String == "Texto posterior")
    }

    @Test @MainActor func dynamicCoordinatorDiscardsLateResultAfterStopAndNavigation() async throws {
        for operation in ["stop", "navigate", "sameURL"] {
            let tab = try await Self.dynamicTab()
            defer { tab.close() }
            var held: CheckedContinuation<Void, Never>?
            let translation = PageTranslation(translator: { batch, _, _ in
                if batch.contains(where: { $0["text"] == "Texto del diálogo" }) {
                    await withCheckedContinuation { held = $0 }
                }
                return Self.dictionary(batch)
            })
            translation.translate(tab, to: Locale.Language(identifier: "en"))
            #expect(try await Self.eventually { translation.phase(for: tab) == .translated })
            _ = try await tab.page.fixtureExpression("document.getElementById('open').click()")
            let waiting = try await Self.eventually { held != nil }
            #expect(waiting)
            guard waiting else { translation.forget(tab); continue }
            if operation == "stop" {
                translation.stop(tab)
            } else {
                let url = operation == "sameURL" ? "https://example.test/dynamic" : "https://example.test/next"
                tab.page.navigate(html: "<html lang=es><h1 id=initial>Nueva página</h1><p id=dialog>Texto nuevo</p></html>", base: URL(string: url))
                #expect(try await Self.eventually {
                    try await tab.page.fixtureExpression("document.getElementById('initial')?.textContent") as? String == "Nueva página"
                })
                if operation == "navigate" { translation.navigationCommitted(tab) }
                else {
                    // Same URL and same view still pass the old Swift guards.
                    // A new document adapter must reject the previous token.
                    _ = try await Self.collect(tab.page)
                }
            }
            held?.resume(); held = nil
            try await Task.sleep(for: .milliseconds(100))
            #expect(try await tab.page.fixtureExpression("document.getElementById('dialog').textContent") as? String == (operation == "stop" ? "Texto del diálogo" : "Texto nuevo"))
            if operation == "sameURL" { translation.navigationCommitted(tab) }
            #expect(translation.phase(for: tab) == .original)
            translation.forget(tab)
            _ = await Self.inPage(tab.page, "window.__yabPageTranslation?.restore()")
        }
    }
    @Test @MainActor func nativeDynamicTranslationOnlyWithInstalledModels() async throws {
        let source = Locale.Language(identifier: "es"), target = Locale.Language(identifier: "en")
        let status = await LanguageAvailability().status(from: source, to: target)
        guard status == .installed else {
            print("1291_NATIVE_DYNAMIC_UNRUN: es-en models are not installed; no download or model host started")
            return
        }
        let tab = try await Self.dynamicTab(), translation = PageTranslation()
        let host = NSHostingView(rootView: PageTranslationHost(translation: translation).frame(width: 1, height: 1))
        let window = NSWindow(contentRect: NSRect(x: -1000, y: -1000, width: 20, height: 20),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host; window.orderFront(nil)
        defer { translation.forget(tab); tab.close(); window.orderOut(nil) }
        translation.translate(tab, to: target)
        #expect(try await Self.eventually(attempts: 600) { translation.phase(for: tab) == .translated })
        _ = try await tab.page.fixtureExpression("document.getElementById('open').click(); document.getElementById('reveal').click()")
        #expect(try await Self.eventually(attempts: 600) {
            try await tab.page.fixtureExpression("(() => { const d=document.getElementById('dialog'),s=document.getElementById('lateral'); return !!d && !!s && !!d.textContent.trim() && !!s.textContent.trim() && d.textContent !== 'Texto del diálogo' && s.textContent !== 'Texto lateral'; })()") as? Bool == true
        })
        translation.toggle(tab)
        #expect(try await Self.eventually {
            try await tab.page.fixtureExpression("document.getElementById('initial')?.textContent === 'Texto inicial' && document.getElementById('dialog')?.textContent === 'Texto del diálogo' && document.getElementById('lateral')?.textContent === 'Texto lateral'") as? Bool == true
        })
        print("1291_NATIVE_DYNAMIC_RAN: installed es-en; assertions determine pass, original reporter profile remains unverified")
    }
    // END 1291 CANDIDATE COORDINATOR

}
