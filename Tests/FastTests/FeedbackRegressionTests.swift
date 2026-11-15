import AppKit
import Testing
import WebKit
@testable import Fast
@testable import MailCore

@MainActor
@Suite(.serialized)
struct FeedbackRegressionTests {
    @Test func draggingPastEitherEndAlwaysHasAValidInsertionIndex() {
        let folders = Folders(emptiesFile: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        for count in [1, 2, 3, 20] {
            let tabs = (0..<count).map { _ in Tab() }
            for held in tabs {
                for want in [-Double.greatestFiniteMagnitude, -100, -1, 0, 1, 7, 100, Double.greatestFiniteMagnitude] {
                    let landing = folders.landing(held, want: want, among: tabs)
                    #expect((0..<count).contains(landing.index))
                }
                for want in [Double.nan, Double.infinity, -Double.infinity] {
                    #expect(folders.landing(held, want: want, among: tabs).index == tabs.firstIndex { $0 === held })
                }
            }
        }
    }

    /// #164: Copy Email Address on a mailto: link copies the address
    /// alone.
    @Test func copyEmailAddressIsTheBareAddress() throws {
        let address = { (link: String) in PageView.emailAddress(try #require(URL(string: link))) }
        #expect(try address("mailto:ines@northwind.studio") == "ines@northwind.studio")
        #expect(try address("MAILTO:Ines.Costa@northwind.studio?subject=Hi%20there&cc=team@northwind.studio") == "Ines.Costa@northwind.studio")
        #expect(try address("mailto:ines%40northwind.studio") == "ines@northwind.studio")
        #expect(try address("mailto:a@b.co,c@d.co?subject=x") == "a@b.co,c@d.co")
        #expect(try address("mailto:?subject=Nobody") == nil)
        #expect(try address("https://northwind.studio/contact") == nil)
        #expect(try address("tel:+15551234567") == nil)
    }

    /// #164: the feedback card keeps the address the last report went
    /// with, on this Mac alone, and forgets it when one goes without.
    @Test func feedbackRemembersTheLastEmail() {
        let before = Store.settings.string(forKey: FeedbackSheet.emailKey)
        defer { Store.settings.set(before, forKey: FeedbackSheet.emailKey) }
        FeedbackSheet.remember(email: "  nirmal@example.com ")
        #expect(FeedbackSheet.Draft().email == "nirmal@example.com")
        #expect(!SyncShapes.syncs(FeedbackSheet.emailKey))
        FeedbackSheet.remember(email: " ")
        #expect(Store.settings.string(forKey: FeedbackSheet.emailKey) == nil)
        #expect(FeedbackSheet.Draft().email == "")
    }

    @Test func alternateReturnDuplicatesCurrentAddressAhead() {
        let id = UUID(), browser = Browser(windowID: UUID())
        defer {
            browser.tabs.forEach { $0.close() }
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        let first = browser.open(URL(string: "about:blank#\(id)")!, foreground: true)
        browser.edit()
        browser.submitAlternate()
        #expect(browser.tabs.count == 2)
        #expect(browser.active !== first)
        #expect(browser.active?.address == first.address)
    }

    @Test func explicitNewTabDoesNotSwitchToAnExistingSuggestion() {
        let browser = Browser(windowID: UUID())
        let url = URL(string: "https://example.test/existing")!
        let original = browser.open(url, foreground: true)
        defer {
            browser.tabs.forEach { $0.close() }
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        browser.take(Suggestion(key: "existing", title: "Existing", url: url, kind: .open, tab: original.id), .ahead, copyingTab: true)
        #expect(browser.tabs.count == 2)
        #expect(browser.active !== original)
        #expect(browser.active?.address == url)
    }

    @Test func keepCommandTogglesTheSelectedTab() {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "https://example.test/kept")!, foreground: true)
        defer {
            browser.tabs.forEach { $0.close() }
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        browser.toggleKeepTabs()
        #expect(tab.kept)
        browser.toggleKeepTabs()
        #expect(!tab.kept)
        #expect(Shortcut.items.contains { $0.action == .keepTab })
    }

    @Test func translationMenuBelongsToThePage() throws {
        let translation = PageTranslation(), page = Tab(), blank = Tab()
        page.restore(url: URL(string: "https://example.test/article")!, title: "Article")
        let item = try #require(translation.menuItem(for: page))
        #expect(item.title == "Translate Page to \(translation.targetName)")
        #expect(item.isEnabled)
        #expect(translation.menuItem(for: blank) == nil)
        // Beside it, Translate To: the page in another language.
        let rows = translation.menuItems(for: page)
        #expect(rows.map(\.title) == ["Translate Page to \(translation.targetName)", "Translate To"])
        #expect(rows.last?.submenu?.items.isEmpty == false)
        #expect(translation.menuItems(for: blank).isEmpty)
    }

    /// Translate To lists the Mac's own languages first, as the Mac has them,
    /// then every other language macOS translates into, each once, by name.
    @Test func translateToListsTheMacsLanguagesFirstThenEachOtherOnce() {
        let supported = ["en-IN", "it-CH", "ko", "en", "en-GB", "zh-TW", "fr", "fr-CA", "zh", "ru", "pt", "pt-PT", "zh-HK", "de"]
            .map { Locale.Language(identifier: $0) }
        let english = Locale(identifier: "en_US")
        let (mine, others) = PageTranslation.choices(supported: supported, preferred: ["ru-GB", "en-GB", "en-US", "be"], in: english)
        #expect(mine.map(\.name) == ["Russian", "English"])
        #expect(mine.map(\.language.minimalIdentifier) == ["ru", "en-GB"])
        let names = others.map(\.name)
        #expect(names.count == 7)
        #expect(Array(names.dropFirst(2)) == ["French", "German", "Italian", "Korean", "Portuguese"])
        // Chinese is written two ways, and each is a row of its own.
        #expect(names.prefix(2).allSatisfy { $0.hasPrefix("Chinese") } && Set(names.prefix(2)).count == 2)
        #expect(others.first { $0.name == "French" }?.language.minimalIdentifier == "fr")
        // Before macOS has said, the Mac's own languages alone.
        let waiting = PageTranslation.choices(supported: [], preferred: ["ru", "en-US", "en-GB"], in: english)
        #expect(waiting.mine.map(\.name) == ["Russian", "English"])
        #expect(waiting.others.isEmpty)
    }

    /// Register #1103: Translate To is the Mac's languages and the ones
    /// picked lately; the rest wait under More Languages.
    @Test func translateToKeepsRecentLanguagesBesideTheMacs() {
        let supported = ["en", "fr", "de", "ja", "ko", "es"].map { Locale.Language(identifier: $0) }
        let english = Locale(identifier: "en_US")
        var recent = PageTranslation.remembering(Locale.Language(identifier: "ja"), in: [])
        recent = PageTranslation.remembering(Locale.Language(identifier: "fr-CA"), in: recent)
        recent = PageTranslation.remembering(Locale.Language(identifier: "ja-JP"), in: recent)
        #expect(recent == ["ja", "fr-CA"])
        recent = ["de", "ko", "es"].reduce(recent) { PageTranslation.remembering(Locale.Language(identifier: $1), in: $0) }
        #expect(recent == ["es", "ko", "de"])
        let (mine, others) = PageTranslation.choices(supported: supported, preferred: ["en-US"] + ["fr", "ja"], in: english)
        #expect(mine.map(\.name) == ["English", "French", "Japanese"])
        #expect(others.map(\.name) == ["German", "Korean", "Spanish"])
    }

    /// Register #1103: View › Translate Page is one action under its three
    /// titles, so a key from App Shortcuts or Settings › Shortcuts holds.
    @Test @MainActor func translatePageIsOnTheMenuBarUnderOneAction() {
        #expect(Shortcut.titles[.translatePage] == "Translate Page")
        for title in PageTranslation.barTitles { #expect(Hotkeys.action(forTitle: title) == .translatePage) }
        #expect(Shortcut.items.contains { $0.action == .translatePage })
        let translation = PageTranslation(), page = Tab(), blank = Tab()
        page.restore(url: URL(string: "https://example.test/article")!, title: "Article")
        #expect(translation.barTitle(for: page) == "Translate Page")
        #expect(translation.canTranslate(page))
        #expect(!translation.canTranslate(blank))
        #expect(!translation.canTranslate(nil))
    }

    @Test func remindersDismissOnceAndRescheduledOccurrencesReturn() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let link = URL(string: "https://meet.google.com/abc-defg-hij")!
        let meeting = Meeting(id: "one", title: "Standup", start: now.addingTimeInterval(45), end: now.addingTimeInterval(1800), link: link)
        var state = MeetingReminders()
        #expect(state.next(in: [meeting], at: now.addingTimeInterval(-30)) == nil)
        #expect(state.next(in: [meeting], at: now) == meeting)
        state.dismiss(meeting)
        #expect(state.next(in: [meeting], at: now.addingTimeInterval(60)) == nil)
        let moved = Meeting(id: "one", title: "Standup", start: now.addingTimeInterval(90), end: meeting.end, link: link)
        #expect(state.next(in: [moved], at: now.addingTimeInterval(60)) == moved)
        #expect(state.next(in: [moved], at: now.addingTimeInterval(300)) == nil)
        #expect(state.next(in: [], at: now) == nil)
    }

    /// ⌘W on the last tab closes it for good: its sound stops, and Escape
    /// brings nothing back.
    @Test func closingLastTabStopsItsMedia() async throws {
        let browser = Browser(windowID: UUID())
        let config = Web.configuration(shy: true)
        config.mediaTypesRequiringUserActionForPlayback = []
        let tab = Tab(configuration: config, factory: .webKitOnly)
        tab.setAddressOptimistically(URL(string: "https://example.test/media")!)
        browser.prepare(tab)
        browser.lay([tab])
        browser.activeID = tab.id
        let web = requireNativeWebKitFixture(tab, "FeedbackRegressionTests")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            tab.close()
            if let id = browser.windowID { try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json")) }
        }
        // A silent WAV plays indefinitely, without network or audible test output.
        web.loadHTMLString("""
        <audio id="audio" loop></audio><script>
        const data = new Uint8Array(8044), v = new DataView(data.buffer);
        for (const [p,s] of [[0,'RIFF'],[8,'WAVE'],[12,'fmt '],[36,'data']]) for(let i=0;i<s.length;i++) data[p+i]=s.charCodeAt(i);
        v.setUint32(4,8036,true); v.setUint32(16,16,true); v.setUint16(20,1,true); v.setUint16(22,1,true);
        v.setUint32(24,8000,true); v.setUint32(28,8000,true); v.setUint16(32,1,true); v.setUint16(34,8,true); v.setUint32(40,8000,true);
        data.fill(128,44); const player=document.getElementById('audio');
        player.src=URL.createObjectURL(new Blob([data],{type:'audio/wav'}));
        player.play().catch(e=>window.playbackFailure=e.message);
        </script>
        """, baseURL: URL(string: "https://example.test/media"))
        for _ in 0..<100 {
            if await web.requestMediaPlaybackState() == .playing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let before = await web.requestMediaPlaybackState()
        let diagnostic = try? await web.evaluateJavaScript("JSON.stringify({url:location.href, failure:window.playbackFailure, ready:document.querySelector('audio')?.readyState, paused:document.querySelector('audio')?.paused})")
        #expect(before == .playing, "Media fixture: \(String(describing: diagnostic))")
        browser.shut([tab])
        #expect(browser.under == nil && browser.tabs.isEmpty)
        // Its media is suspended at once, and the page is seen off (Farewell,
        // 747fb83d): taken to an empty page so its goodbye still leaves, then
        // ended (Tab.end) whatever still holds its view, 1.5 s at most. Then
        // nothing is left to play: WebKit says no media at all, where a page
        // only suspended says suspended. Either is silence; playing or paused
        // is a page still alive.
        for _ in 0..<60 {
            if (web.value(forKey: "_isClosed") as? Bool) == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect((web.value(forKey: "_isClosed") as? Bool) == true)
        let shut = await web.requestMediaPlaybackState()
        #expect(shut == .none || shut == .suspended, "media after closing: \(shut.rawValue)")
        browser.dismiss()
        #expect(browser.active == nil && browser.tabs.isEmpty)
        let dismissed = await web.requestMediaPlaybackState()
        #expect(dismissed == .none || dismissed == .suspended, "media after Escape: \(dismissed.rawValue)")
    }
}
