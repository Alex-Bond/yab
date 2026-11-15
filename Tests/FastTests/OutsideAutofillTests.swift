import AppKit
import Testing
import WebKit
@testable import Fast

// Run with ./farm exec --display -- python3 scripts/tests/run-autofill-native.py.
// AppKit owns the main loop; ordinary swift test leaves this native suite disabled.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["YAB_NATIVE_TEST_HOST"] == "1"))
@MainActor
struct OutsideAutofillTests {
    private func waitForKeyWindow(_ window: NSWindow) async throws {
        let deadline = Date(timeIntervalSinceNow: 5)
        while Date() < deadline {
            if NSApp.isActive, window.isKeyWindow { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(NSApp.isActive)
        try #require(window.isKeyWindow)
    }

    private func makeKeyWindow(_ window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await waitForKeyWindow(window)
    }

    @MainActor
    private struct Fixture {
        let browser: Browser
        let tab: Tab
        let window: NSWindow
        let host: PageSuggestionsHost
        let spot: CGRect
        let windowID: UUID

        func close() {
            window.orderOut(nil)
            browser.letGo(outside: tab)
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
        }
    }

    private func fixture() async throws -> Fixture {
        try #require(NSApp.isRunning)
        let id = UUID(), browser = Browser(windowID: id)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Exercise the actual selected engine and its AppKit input client.
        let tab = Tab(bench: true, configuration: configuration, factory: .standard)
        tab.setAddressOptimistically(URL(string: "https://autofill.test/")!)
        browser.outside.append(tab)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 480))
        let holder = PageHolder(tab: tab)
        holder.frame = NSRect(x: 19, y: 23, width: 580, height: 420)
        content.addSubview(holder)
        let host = PageSuggestionsHost(browser: browser, tab: tab)
        host.frame = holder.frame
        content.addSubview(host)
        let window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 620, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = content
        let spot = CGRect(x: 35, y: 41, width: 280, height: 36)
        let codes = [
            SentCode(id: "fixture-first", code: "135790", from: "Autofill fixture", at: nil, source: .text, mine: true),
            SentCode(id: "fixture-second", code: "246801", from: "Autofill fixture", at: nil, source: .text, mine: true),
        ]
        browser.codeList = Browser.CodeChoices(tab: tab.id, spot: spot, codes: codes,
                                               site: "autofill.test", appleAccount: nil, dark: false)
        let fixture = Fixture(browser: browser, tab: tab, window: window, host: host, spot: spot, windowID: id)
        do {
            try await makeKeyWindow(window)
            try #require(window.makeFirstResponder(tab.page))
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    private func key(_ code: UInt16, window: NSWindow, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                     characters: code == 53 ? "\u{1b}" : "\r",
                                     charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r",
                                     isARepeat: false, keyCode: code))
    }

    @Test func anOutsidePagesListTakesArrowsAndReturnInItsOwnWindow() async throws {
        let f = try await fixture()
        defer { f.close() }
        #expect(f.browser.activeID != f.tab.id)
        #expect(f.browser.offersAutofill(f.tab))
        f.tab.page.navigate(html: "<!doctype html><title>Code fixture</title><input id=code autocomplete=one-time-code>",
                                base: URL(string: "https://autofill.test/"))
        var ready = false
        for _ in 0..<200 {
            ready = (try? await f.tab.page.fixtureExpression("!!document.querySelector('#code')")) as? Bool == true
            if ready, !f.tab.page.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ready)
        _ = try await f.tab.page.fixtureExpression("document.querySelector('#code').focus(); true")
        for _ in 0..<200 {
            if f.tab.fieldCode, f.tab.fieldDocument != nil, f.tab.fieldIdentity != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(f.tab.fieldCode)
        // The fixture supplies its two code rows, but their watcher must still
        // belong to the REAL focused document/field/request, just as codeField
        // binds it in a normally prepared browser window.
        f.browser.codeWatch.document = try #require(f.tab.fieldDocument)
        f.browser.codeWatch.field = try #require(f.tab.fieldIdentity)
        f.browser.codeWatch.request = f.tab.fieldCodeRequest
        #expect(f.browser.autofillKey(try key(125, window: f.window), on: f.tab))
        #expect(f.browser.codeLit == 1)
        #expect(f.browser.autofillKey(try key(36, window: f.window), on: f.tab))
        #expect(f.browser.codeList == nil)
        var filled = false
        for _ in 0..<100 {
            // Only a boolean leaves the fixture page, never a filled value.
            filled = (try? await f.tab.page.fixtureExpression("document.querySelector('#code').value === '246801'")) as? Bool == true
            if filled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(filled)
    }

    @Test func appKitKnowsAnEmailIsNotTheCodeFieldBesideIt() async throws {
        let f = try await fixture()
        defer { f.close() }
        let web = f.tab.page
        let content = try #require(web as? any NSTextContent)
        web.navigate(html: """
        <!doctype html><title>Input content fixture</title>
        <form><label for="email">Email</label><input id="email" type="email" autocomplete="username">
        <input id="password" type="password" autocomplete="current-password"></form>
        <label for="verified">Verification email</label><input id="verified" autocomplete="email">
        <input id="code" autocomplete="one-time-code">
        <div><p>Verification Code</p><input id="inferred" inputmode="numeric" maxlength="6" placeholder="000000"></div>
        <input id="phone" type="tel"><input id="url" type="url"><textarea id="message"></textarea>
        <button id="done">Done</button>
        """, base: URL(string: "https://autofill.test/"))
        var ready = false
        for _ in 0..<200 {
            ready = (try? await web.fixtureExpression("!!document.querySelector('#done')")) as? Bool == true
            if ready, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready)
        let cases: [(String, NSTextContentType?)] = [
            ("email", .emailAddress), ("password", .password), ("verified", .emailAddress),
            ("code", .oneTimeCode), ("email", .emailAddress), ("inferred", .oneTimeCode),
            ("phone", .telephoneNumber), ("url", .URL), ("message", nil), ("done", .URL),
        ]
        for (id, expected) in cases {
            _ = try await web.fixtureExpression("document.getElementById('\(id)').focus(); true")
            for _ in 0..<200 {
                if content.contentType == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(content.contentType == expected, "native content type for \(id)")
            // This is the Objective-C getter AppKit reads, not just Swift state.
            #expect(web.value(forKey: "contentType") as? String == expected?.rawValue)
            if id != "done" {
                for _ in 0..<200 {
                    if web.inputContext != nil { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                let client = try #require(web.inputContext?.client as? NSTextContent)
                #expect(client.contentType == expected, "active AppKit input client for \(id)")
            }
        }
        #expect(try await web.fixtureExpression("document.getElementById('email').getAttribute('autocomplete')") as? String == "username")
        #expect(try await web.fixtureExpression("document.getElementById('verified').getAttribute('autocomplete')") as? String == "email")
        #expect(try await web.fixtureExpression("document.getElementById('inferred').getAttribute('autocomplete')") as? String == "one-time-code")
    }

    @Test func aChildFramesInputHintEndsWithItsOwnFocus() async throws {
        let f = try await fixture()
        defer { f.close() }
        let page = f.tab.page
        let content = try #require(page as? any NSTextContent)
        page.navigate(html: """
        <!doctype html><title>Frame input fixture</title>
        <iframe id="child" srcdoc='<form><input id="email" type="email" autocomplete="username"><input id="password" type="password" autocomplete="current-password"><button id="done" type="button">Done</button></form>'></iframe>
        """, base: URL(string: "https://autofill.test/"))
        var ready = false
        for _ in 0..<200 {
            ready = (try? await page.fixtureExpression("!!frames[0]?.document.getElementById('done')")) as? Bool == true
            if ready, !page.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(ready)
        let cases: [(String, NSTextContentType?)] = [("email", .emailAddress), ("password", .password), ("done", .URL)]
        for (field, expected) in cases {
            _ = try await page.fixtureExpression("frames[0].document.getElementById('\(field)').focus(); true")
            for _ in 0..<200 {
                if content.contentType == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(content.contentType == expected, "authenticated frame hint for \(field)")
        }
    }

    @Test func anSMSChallengeUsesItsNewestTextAndStopsWhenYouType() async throws {
        let f = try await fixture()
        defer { f.close() }
        try #require(!MailCenter.shared.connected)
        let prefs = f.browser.prefs
        let hadMail = prefs.mailCodes, hadTexts = Store.settings.object(forKey: "codes.texts")
        let hadCodesFromTexts = prefs.codesFromTexts
        prefs.mailCodes = true
        prefs.textCodes = true
        let now = Date()
        MailCodes.fakeMail.withLock {
            $0 = [Mailed(from: "Autofill", address: "login@autofill.test", subject: "Your code",
                         text: "Code: 135790", at: now)]
        }
        AgentFiles.fakeTexts.withLock {
            $0 = [(text: "Autofill: code 111111", at: now.addingTimeInterval(-180), from: "Fixture"),
                  (text: "Autofill: code 2468", at: now, from: "Fixture"),
                  (text: "Autofill: code 246801", at: now.addingTimeInterval(-1), from: "Fixture")]
        }
        defer {
            f.browser.codeWatch.stop()
            MailCodes.fakeMail.withLock { $0 = nil }
            AgentFiles.fakeTexts.withLock { $0 = nil }
            prefs.mailCodes = hadMail
            prefs.codesFromTexts = hadCodesFromTexts
            if let hadTexts { Store.settings.set(hadTexts, forKey: "codes.texts") }
            else { Store.settings.removeObject(forKey: "codes.texts") }
        }
        f.browser.codeList = nil
        f.browser.prepare(f.tab)
        let web = f.tab.page
        web.navigate(html: """
        <!doctype html><title>SMS verification fixture</title>
        <main><h1>Verify that it's you</h1><section>
        <p id="prompt">A text message with a 6-digit verification code was just sent to your phone.</p>
        <div><div><div><div><div><div><div><div><label for="code">Enter the code</label><span>G-</span><input id="code" autocomplete="one-time-code" maxlength="8"></div></div></div></div></div></div></div></div>
        </section></main>
        """, base: URL(string: "https://autofill.test/"))
        for _ in 0..<200 {
            if (try? await web.fixtureExpression("!!document.getElementById('code')")) as? Bool == true, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await web.fixtureExpression("document.getElementById('code').focus(); true")
        for _ in 0..<300 {
            if f.browser.codeList?.codes.map(\.code) == ["246801"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.tab.fieldCodeRequest == CodeRequest(source: .text, digits: 6))
        #expect(f.browser.codeList?.codes.map(\.code) == ["246801"])
        #expect(f.browser.codeList?.codes.allSatisfy { $0.source == .text } == true)
        #expect(f.browser.codeWatch.mail.isEmpty)
        _ = try await web.fixtureExpression("document.getElementById('code').value = '357'; document.getElementById('code').dispatchEvent(new InputEvent('input', {bubbles:true})); true")
        for _ in 0..<200 {
            if !f.tab.fieldEmpty, f.browser.codeList == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!f.tab.fieldEmpty)
        #expect(f.browser.codeList == nil)
        #expect(f.browser.codeWatch.tab == nil)
        #expect(f.browser.codeWatch.timer == nil)
        // A pending DOM fill cannot replace input, even before its relay arrives.
        let filled = try await web.fixtureFunction(MailCodes.fill, arguments: ["code": "246801"])
        #expect(filled as? Bool == false)
        #expect(try await web.fixtureExpression("document.getElementById('code').value === '357'") as? Bool == true)
        try await Task.sleep(for: .milliseconds(3200))
        #expect(f.browser.codeList == nil)
        _ = try await web.fixtureExpression("document.getElementById('code').value = ''; document.getElementById('code').dispatchEvent(new InputEvent('input', {bubbles:true})); true")
        for _ in 0..<400 {
            if f.browser.codeList?.codes.map(\.code) == ["246801"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.browser.codeList?.codes.map(\.code) == ["246801"], "\(codeState(f))")
        // The same box can become an email challenge without navigating.
        _ = try await web.fixtureExpression("document.getElementById('prompt').textContent = 'An email with a 6-digit verification code was sent.'; document.getElementById('code').dispatchEvent(new InputEvent('input', {bubbles:true})); true")
        for _ in 0..<400 {
            if f.browser.codeList?.codes.map(\.code) == ["135790"] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.tab.fieldCodeRequest == CodeRequest(source: .mail, digits: 6))
        #expect(f.browser.codeList?.codes.map(\.code) == ["135790"], "\(codeState(f))")
    }

    private func codeState(_ fixture: Fixture) -> String {
        let tab = fixture.tab, watch = fixture.browser.codeWatch
        return "key=\(fixture.window.isKeyWindow), eligible=\(fixture.browser.offersAutofill(tab)), "
            + "empty=\(tab.fieldEmpty), code=\(tab.fieldCode), watching=\(watch.tab == tab.id), "
            + "reading=\(watch.reading), sameDocument=\(watch.document == tab.fieldDocument), "
            + "sameField=\(watch.field == tab.fieldIdentity), sameRequest=\(watch.request == tab.fieldCodeRequest)"
    }

    @Test func codeInstructionsStayWithTheirOwnField() async throws {
        let f = try await fixture()
        defer { f.close() }
        let web = f.tab.page
        web.navigate(html: """
        <!doctype html><title>Code instructions fixture</title>
        <section><p>A text message with a 6-digit verification code was sent.</p><input id="sms" autocomplete="one-time-code"></section>
        <section><p>Enter the 4-digit code from your email.</p><input id="mail" autocomplete="one-time-code" maxlength="4"></section>
        <section><p>Enter your authenticator code.</p><div id="split">
        <input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1"><input maxlength="1">
        </div></section>
        <section><input id="unknown" autocomplete="one-time-code" pattern="[0-9]{8}"></section>
        """, base: URL(string: "https://autofill.test/"))
        for _ in 0..<200 {
            if (try? await web.fixtureExpression("!!document.getElementById('unknown')")) as? Bool == true, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let cases: [(String, CodeRequest)] = [
            ("#sms", CodeRequest(source: .text, digits: 6)),
            ("#mail", CodeRequest(source: .mail, digits: 4)),
            ("#split input", CodeRequest(source: .key, digits: 6)),
            ("#unknown", CodeRequest(digits: 8)),
        ]
        for (selector, expected) in cases {
            _ = try await web.fixtureExpression("document.querySelector('\(selector)').focus(); true")
            for _ in 0..<200 {
                if f.tab.fieldCodeRequest == expected { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(f.tab.fieldCode)
            #expect(f.tab.fieldCodeRequest == expected, "instructions for \(selector)")
        }
    }

    @Test func aNativeListTakesOnlyClicksInsideItsRows() async throws {
        let f = try await fixture()
        defer { f.close() }
        let inside = NSPoint(x: f.spot.minX + 24, y: f.spot.maxY + 26)
        let insideInContent = f.host.convert(inside, to: f.host.superview)
        var hit: NSView?
        for _ in 0..<100 {
            f.host.layoutSubtreeIfNeeded()
            hit = f.host.hitTest(insideInContent)
            if hit != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(hit != nil)
        let fieldInContent = f.host.convert(NSPoint(x: f.spot.midX, y: f.spot.midY), to: f.host.superview)
        #expect(f.host.hitTest(fieldInContent) == nil)
        let elsewhereInContent = f.host.convert(NSPoint(x: 540, y: 370), to: f.host.superview)
        #expect(f.host.hitTest(elsewhereInContent) == nil)
        f.browser.codeList = nil
        #expect(f.host.hitTest(insideInContent) == nil)
    }

    @Test func aHiddenPeekAncestorCannotOfferAutofillInAKeyWindow() async throws {
        let f = try await fixture()
        defer { f.close() }
        #expect(f.window.isKeyWindow)
        f.tab.page.superview?.isHidden = true
        #expect(!f.browser.offersAutofill(f.tab))
    }

    @Test func aHiddenOutsidePageCannotTakeAListKey() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.window.orderOut(nil)
        #expect(!f.browser.offersAutofill(f.tab))
        #expect(!f.browser.autofillKey(try key(125, window: f.window), on: f.tab))
        #expect(f.browser.codeLit == 0)
    }

    @Test func choosingFromTheFullListReturnsTheKeyboardToTheSmallWindow() async throws {
        let f = try await fixture()
        defer { f.close() }
        let picker = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer { picker.orderOut(nil) }
        try await makeKeyWindow(picker)
        #expect(!f.window.isKeyWindow)
        f.browser.handBack(to: f.tab)
        try await waitForKeyWindow(f.window)
        #expect(f.window.isKeyWindow)
        let responder = f.window.firstResponder as? NSView
        #expect(responder === f.tab.builtPage || responder?.isDescendant(of: f.tab.page) == true)
    }

    @Test func aSelectedMainPageCannotOfferAutofillBehindAnotherWindow() async throws {
        let f = try await fixture()
        defer { f.close() }
        f.browser.takeIn(f.tab)
        #expect(f.browser.activeID == f.tab.id)
        #expect(f.browser.offersAutofill(f.tab))
        let another = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        defer { another.orderOut(nil) }
        try await makeKeyWindow(another)
        #expect(!f.browser.offersAutofill(f.tab))
        try await makeKeyWindow(f.window)
        #expect(f.browser.offersAutofill(f.tab))
    }

    @Test func aListNeverTakesKeysFromAnotherWindowOrACommandShortcut() async throws {
        let f = try await fixture()
        defer { f.close() }
        let another = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 200, height: 100),
                               styleMask: [.titled], backing: .buffered, defer: false)
        another.orderFront(nil)
        defer { another.orderOut(nil) }
        #expect(!f.browser.autofillKey(try key(125, window: another), on: f.tab))
        #expect(!f.browser.autofillKey(try key(36, window: f.window, flags: .command), on: f.tab))
        #expect(f.browser.codeLit == 0)
    }
}
