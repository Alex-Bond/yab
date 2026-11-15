import AppKit
import Darwin
import Testing
import WebKit
@testable import Fast

/// Real opener/child WebKit documents and native panels. Lifecycle calls use
/// fixture-only activation; separate owned-view AppKit key tests require
/// the engine's trusted gesture and retain the normal popup policy.
@MainActor
@Suite(.serialized, .enabled("no test screen; the built-in one is off-limits") { await TestScreen.available })
struct DocumentPiPTests {
    private nonisolated static let exitTrace: Int32 = {
        guard ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1" else { return 0 }
        return atexit {
            let stack = Thread.callStackSymbols.joined(separator: "\n")
            FileHandle.standardError.write(Data("DocumentPiP test process atexit stack:\n\(stack)\n".utf8))
        }
    }()

    private nonisolated static func traceHarness(_ step: String) {
        guard ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1" else { return }
        FileHandle.standardError.write(Data("DocumentPiP harness: \(step)\n".utf8))
    }

    @MainActor
    private final class Fixture {
        let browser: Browser
        let source: Tab
        let window: NSWindow
        let windowID: UUID

        init(automaticPopups: Bool = true) {
            _ = DocumentPiPTests.exitTrace
            DocumentPiPTests.traceHarness("fixture init automatic=\(automaticPopups)")
            windowID = UUID()
            browser = Browser(windowID: windowID)
            DocumentPiPTests.traceHarness("fixture Browser made")
            let sourceURL = URL(string: "about:blank#document-pip-source")!
            // This suite exercises native WK document-picture-in-picture APIs.
            source = Tab(shy: !automaticPopups, bench: automaticPopups, factory: .webKitOnly)
            browser.prepare(source)
            browser.lay(browser.tabs + [source])
            source.go(to: sourceURL)
            DocumentPiPTests.traceHarness("fixture source made")
            _ = browser.benchOpen(URL(string: "about:blank#document-pip-other")!)
            browser.activeID = source.id
            DocumentPiPTests.traceHarness("fixture row selected")
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Document PiP source fixture"
            // On the test screen so the PiP panel opens there too, never on
            // the screen the user works on; unseen unless a test needs it.
            if let screen = TestScreen.screen {
                let visible = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visible.minX + 48,
                    y: max(visible.minY, visible.maxY - window.frame.height - 48)))
            }
            if automaticPopups { window.alphaValue = 0 }
            requireNativeWebKitFixture(source, "DocumentPiPTests").autoresizingMask = [.width, .height]
            window.contentView = requireNativeWebKitFixture(source, "DocumentPiPTests")
            window.orderFront(nil)
            DocumentPiPTests.traceHarness("fixture window attached")
        }

        func close() {
            DocumentPiPTests.traceHarness("fixture close begin")
            source.documentPiP.didClose()
            for tab in browser.tabs + browser.outside + browser.parkedTabs { tab.close() }
            window.close()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(windowID.uuidString).json"))
            DocumentPiPTests.traceHarness("fixture close end")
        }
    }

    private let page = """
    <!doctype html><html><head><title>Document PiP fixture</title>
    <script>
      window.availableAtStart = typeof window.documentPictureInPicture?.requestWindow === 'function';
      window.readActivationState = () => {
        let owner = navigator, descriptor;
        while (owner && !(descriptor = Object.getOwnPropertyDescriptor(owner, 'userActivation')))
          owner = Object.getPrototypeOf(owner);
        const value = navigator.userActivation;
        return {
          type: typeof value, tag: Object.prototype.toString.call(value),
          own: Object.prototype.hasOwnProperty.call(navigator, 'userActivation'),
          ownerTag: owner ? Object.prototype.toString.call(owner) : null,
          getter: descriptor?.get ? String(descriptor.get) : null,
          configurable: descriptor?.configurable ?? null,
          isActive: value?.isActive ?? null, hasBeenActive: value?.hasBeenActive ?? null
        };
      };
      window.activationAtStart = window.readActivationState();
      window.inputEvents = [];
      for (const type of ['keydown', 'keyup']) {
        document.addEventListener(type, event => {
          window.inputEvents.push({type, trusted:event.isTrusted, button:event.button,
            buttons:event.buttons, code:event.code, key:event.key, timeStamp:event.timeStamp, target:event.target.id,
            activation:window.readActivationState()});
        }, true);
      }
    </script>
    </head><body><main id="home"><form id="chat"><input id="draft" value="kept draft">
    <button type="submit">Send</button></form></main>
    <script>
      window.originalDocument = document;
      window.chatNode = document.querySelector('#chat');
      window.originalInput = document.querySelector('#draft');
      window.sent = 0; window.lastSent = '';
      window.chatNode.addEventListener('submit', event => {
        event.preventDefault(); window.sent++; window.lastSent = window.originalInput.value;
      });
      window.fixtureReady = true;
    </script></body></html>
    """

    /// Up to 30 s: a WebKit page beside a full test run can take seconds.
    private func wait(_ condition: @MainActor () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try await condition(), "WebKit fixture did not settle")
    }

    private func load(_ fixture: Fixture, at url: URL = URL(string: "https://document-pip.test/chat")!,
                      parserRequest: Bool = false) async throws {
        var html = page
        if parserRequest {
            html = html.replacingOccurrences(of: "</body></html>", with: """
                <script>
                  // Runs in the parser, before native JavaScript evaluation
                  // can grant WebKit's evaluation-only user gesture.
                  window.noGestureActivation = navigator.userActivation?.isActive === true;
                  documentPictureInPicture.requestWindow().then(child => {
                    window.noGestureResult = 'opened'; child.close();
                  }, error => { window.noGestureResult = error.name; });
                </script></body></html>
                """)
        }
        requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").loadHTMLString(html, baseURL: url)
        try await wait {
            let ready = parserRequest
                ? "window.fixtureReady === true && typeof window.noGestureResult === 'string'"
                : "window.fixtureReady === true"
            return (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript(ready)) as? Bool == true
        }
        fixture.source.setAddressOptimistically(url)
    }

    private func makeFixture(automaticPopups: Bool = true, parserRequest: Bool = false) async throws -> Fixture {
        let fixture = Fixture(automaticPopups: automaticPopups)
        do {
            Self.traceHarness("fixture HTML load begin")
            try await load(fixture, parserRequest: parserRequest)
            Self.traceHarness("fixture HTML ready")
            return fixture
        } catch {
            fixture.close()
            throw error
        }
    }

    /// This override exists only inside the isolated HTML fixture. It allows
    /// the lifecycle tests to exercise the native popup without global input.
    private func allowFixtureGesture(on web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("""
            Object.defineProperty(navigator, 'userActivation', {
              configurable: true, value: { isActive: true, hasBeenActive: true }
            }); true
            """)
    }

    /// Send a native Space key only to this fixture's owned WebKit view.
    /// The DOM handler records the engine's trusted activation before calling
    /// the API. No application launch or system input is involved.
    private func pressSpace(_ selector: String, in web: WKWebView) async throws {
        Self.traceHarness("owned key begin \(selector)")
        let window = try #require(web.window)
        try #require(window.makeFirstResponder(web))
        Self.traceHarness("owned key responder set")
        let focused = try await web.callAsyncJavaScript("""
            const button = document.querySelector(selector);
            button.focus(); return document.activeElement === button;
            """, arguments: ["selector": selector], contentWorld: .page) as? Bool
        try #require(focused == true)
        Self.traceHarness("owned key DOM focused")
        // Public WebKit evaluation temporarily grants activation. Let that
        // evaluation finish before sending the independent native key.
        try await Task.sleep(for: .milliseconds(200))
        let down = try key(" ", code: 49, flags: [], in: window)
        try #require(down.window === window)
        Self.traceHarness("owned keyDown dispatch")
        web.keyDown(with: down)
        Self.traceHarness("owned keyDown returned")
        // Let WebKit deliver the event without a native evaluation competing
        // with its gesture scope, then release the owned key.
        try await Task.sleep(for: .milliseconds(200))
        let up = try #require(NSEvent.keyEvent(with: .keyUp, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        web.keyUp(with: up)
        Self.traceHarness("owned keyUp returned")
        try await Task.sleep(for: .milliseconds(100))
    }

    private func key(_ character: String, code: UInt16, flags: NSEvent.ModifierFlags,
                     in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: false, keyCode: code))
    }

    private func diagnose(_ fixture: Fixture, reason: String, before: [UUID]) async {
        guard ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_TRACE"] == "1" else { return }
        let pageState = (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("""
            (() => {
              const result = {
                sourceHref: location.href, sourceReadyState: document.readyState,
                secure: isSecureContext, apiType: typeof window.documentPictureInPicture,
                apiTag: Object.prototype.toString.call(window.documentPictureInPicture),
                clickedTrusted: window.clickedTrusted ?? null,
                clickedActivated: window.clickedActivated ?? null,
                openGestureArrived: window.openGestureArrived ?? null,
                openClicked: window.openClicked ?? null,
                openError: window.openError ?? null,
                openResult: window.openError ? 'rejected' : window.openClicked ? 'resolved' :
                  window.openGestureArrived ? 'pending' : 'not-called',
                activationAtStart: window.activationAtStart ?? null,
                activationBeforeClick: window.activationBeforeClick ?? null,
                activationOnClick: window.activationOnClick ?? null,
                inputEvents: window.inputEvents ?? null,
                activationDuringDiagnosticEvaluation: window.readActivationState?.() ?? null
              };
              const child = window.liveWindow;
              result.liveWindowType = typeof child;
              for (const [name, read] of [
                ['childHref', () => child.location.href],
                ['childClosed', () => child.closed],
                ['childReadyState', () => child.document.readyState],
                ['childHasOriginalInput', () => child.document.querySelector('#draft') === window.originalInput],
                ['apiWindowIsLive', () => documentPictureInPicture.window === child]
              ]) {
                try { result[name] = child ? read() : null; }
                catch (error) { result[name] = error.name + ': ' + error.message; }
              }
              return JSON.stringify(result);
            })()
            """)) as? String ?? "JavaScript diagnostics unavailable"
        let state: [String: Any] = [
            "reason": reason,
            "tabIDsBefore": before.map(\.uuidString),
            "tabsAfter": fixture.browser.tabs.map { ["id": $0.id.uuidString, "url": $0.address?.absoluteString ?? ""] },
            "outsideIDs": fixture.browser.outside.map { $0.id.uuidString },
            "activeID": fixture.browser.activeID?.uuidString ?? "",
            "sourceID": fixture.source.id.uuidString,
            "sourceAddress": fixture.source.address?.absoluteString ?? "",
            "sourceWebURL": requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").url?.absoluteString ?? "",
            "uiDelegate": requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").uiDelegate.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "navigationDelegate": requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").navigationDelegate.map { String(describing: ObjectIdentifier($0)) } ?? "nil",
            "uiDelegateIsBrowser": requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").uiDelegate === fixture.browser,
            "navigationDelegateIsBrowser": requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").navigationDelegate === fixture.browser,
            "manager": String(describing: ObjectIdentifier(fixture.source.documentPiP)),
            "nativeChild": fixture.source.documentPiP.web != nil,
            "nativePanel": fixture.source.documentPiP.panel != nil,
            "managerShowing": fixture.source.documentPiP.showing,
            "sourceWindowVisible": fixture.window.isVisible,
            "sourceWindowKey": fixture.window.isKeyWindow,
            "applicationActive": NSApp.isActive,
            "applicationPolicy": NSApp.activationPolicy().rawValue,
            "applicationDelegateType": NSApp.delegate.map { String(reflecting: type(of: $0)) } ?? "nil",
            "sourceWindowFrame": NSStringFromRect(fixture.window.frame),
            "sourceViewFrame": NSStringFromRect(requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").frame),
            "page": pageState
        ]
        let json = (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "Native diagnostics unavailable"
        print("DocumentPiP fixture diagnostic: \(json)")
    }

    // A window's close button and a titlebar button, as their press acts:
    // performClose and performClick track the button in a nested event
    // loop, and its stop is left for the test process's own main run loop
    // (there is no NSApp.run here), which then returns and ends the whole
    // run with exit 0 halfway through the suite.
    private func pressClose(_ window: NSWindow) {
        if window.delegate?.windowShouldClose?(window) ?? true { window.close() }
    }

    private func press(_ button: NSButton) {
        guard let action = button.action else { return }
        NSApp.sendAction(action, to: button.target, from: button)
    }

    @discardableResult
    private func open(_ fixture: Fixture, options: String = "{width:420,height:280}") async throws -> WKWebView {
        let before = fixture.browser.tabs.map(\.id)
        try await allowFixtureGesture(on: requireNativeWebKitFixture(fixture.source, "DocumentPiPTests"))
        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").callAsyncJavaScript("""
            window.entered = 0;
            documentPictureInPicture.addEventListener('enter', event => {
              window.entered++; window.enteredWindow = event.window;
            }, { once: true });
            window.liveWindow = await documentPictureInPicture.requestWindow(\(options));
            window.liveWindow.addEventListener('pagehide', () => {
              window.pagehid = (window.pagehid || 0) + 1;
              document.querySelector('#home').append(window.chatNode);
            }, { once: true });
            window.liveWindow.document.body.append(window.chatNode);
            return true;
            """, contentWorld: .page)
        if fixture.source.documentPiP.web == nil {
            await diagnose(fixture, reason: "requestWindow resolved without a native child owner", before: before)
        }
        let child = try #require(fixture.source.documentPiP.web)
        try await wait {
            (try? await child.evaluateJavaScript("!!document.querySelector('#draft')")) as? Bool == true
        }
        // The initial about:blank request can commit after requestWindow
        // resolves. Its later commit must not discard the site's moved DOM.
        try await Task.sleep(for: .milliseconds(200))
        try #require(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("liveWindow.document.querySelector('#draft') === originalInput && originalInput.ownerDocument === liveWindow.document") as? Bool == true)
        return child
    }

    @Test func nativeDocumentOwnershipRequiresTheExactOrigin() {
        let current = URL(string: "https://example.test:443/current")!
        #expect(DocumentPiP.sameOrigin(URL(string: "https://example.test/child")!, current))
        for other in ["https://other.example.test/", "http://example.test/", "https://example.test:444/",
                      "https://example.test.evil.test/", "about:blank", "data:text/html,child"] {
            #expect(!DocumentPiP.sameOrigin(URL(string: other)!, current), "\(other)")
        }
    }

    @Test func onlyTheDocumentMarkerIsIntercepted() {
        let marker = "about:blank#__yab_document_pip=fixture-token&disallowReturnToOpener=1&preferInitialWindowPlacement=0"
        #expect(DocumentPiP.isRequest(URL(string: marker)))
        let encoded = "about:blank%23__yab_document_pip=fixture-token&disallowReturnToOpener=1&preferInitialWindowPlacement=0"
        #expect(DocumentPiP.isRequest(URL(string: encoded)))
        #expect(DocumentPiP.canonical(URL(string: encoded)) == URL(string: marker))
        // As WebKit hands it over: bridged from NSURL, whose opaque about:
        // URL has no path or fragment of its own.
        for text in [marker, encoded] {
            let bridged = NSURL(string: text)! as URL
            #expect(DocumentPiP.isRequest(bridged), "bridged \(text)")
            #expect(DocumentPiP.canonical(bridged) == URL(string: marker))
            #expect(!DocumentPiP.isRequest(NSURL(string: "about:blank#other=token")! as URL))
        }
        for text in ["about:blank", "about:blank#__yab_document_pip=", "about:blank#other=token",
                     "about:srcdoc#__yab_document_pip=token", "https://example.test/#__yab_document_pip=token",
                     "about:blank%23other=token", "about:notblank%23__yab_document_pip=token",
                     "about:blankish%23__yab_document_pip=token", "about:blank%2523__yab_document_pip=token",
                     "about:blank%23%5F%5Fyab_document_pip=token",
                     "https://example.test/about:blank%23__yab_document_pip=token"] {
            #expect(!DocumentPiP.isRequest(URL(string: text)), "\(text)")
        }
        #expect(!DocumentPiP.isRequest(nil))
    }

    @Test func knownPlayersAndMeetingURLsKeepTheirExistingPiP() {
        for text in ["https://www.youtube.com/watch?v=fixture", "https://www.twitch.tv/fixture",
                     "https://www.netflix.com/watch/123", "https://meet.google.com/abc-defg-hij",
                     "https://zoom.us/j/123456789", "https://teams.microsoft.com/l/meetup-join/fixture",
                     "https://app.slack.com/huddle/T1/C1"] {
            #expect(DocumentPiP.excluded(URL(string: text)), "\(text)")
        }
        // Chat pages on these same products are not meetings.
        for text in ["https://app.slack.com/client/T1/C1", "https://teams.microsoft.com/v2/",
                     "https://teams.live.com/v2/", "https://meet.google.com/", "https://document-pip.test/chat"] {
            #expect(!DocumentPiP.excluded(URL(string: text)), "\(text)")
        }
    }

    @Test func theChildIsARealOpenerDocumentAndClosingReturnsItsLiveInput() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        let sourceWeb = requireNativeWebKitFixture(fixture.source, "DocumentPiPTests")
        #expect(try await sourceWeb.evaluateJavaScript("window.availableAtStart") as? Bool == true)
        let child = try await open(fixture)
        let panel = try #require(fixture.source.documentPiP.panel)

        #expect(child !== sourceWeb)
        #expect(child.window === panel)
        #expect(panel.level == .floating)
        #expect(fixture.source.documentPiP.showing)
        #expect(DocumentPiP.owner(of: child) === fixture.source)
        #expect(DocumentPiP.owning(page: child) === fixture.source.documentPiP)
        #expect(fixture.source.built === sourceWeb)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
        #expect(try await sourceWeb.evaluateJavaScript("""
            document === originalDocument &&
            liveWindow.opener === window &&
            liveWindow === documentPictureInPicture.window &&
            enteredWindow === liveWindow && entered === 1 &&
            liveWindow.document.querySelector('#draft') === originalInput &&
            originalInput.ownerDocument === liveWindow.document &&
            document.querySelector('#draft') === null
            """) as? Bool == true)
        #expect(try await child.evaluateJavaScript("document.querySelector('#draft').value") as? String == "kept draft")

        // Edit and submit in the child's actual WebKit document. The listener
        // still closes over the opener, so cloning/rendering a stand-in fails.
        _ = try await child.evaluateJavaScript("""
            (() => { const input = document.querySelector('#draft'); input.focus();
              input.setSelectionRange(input.value.length, input.value.length);
              document.execCommand('insertText', false, ' reply');
              document.querySelector('button').click(); return true; })()
            """)
        #expect(try await sourceWeb.evaluateJavaScript("window.sent") as? Int == 1)
        #expect(try await sourceWeb.evaluateJavaScript("window.lastSent") as? String == "kept draft reply")
        if let folder = ProcessInfo.processInfo.environment["YAB_DOCUMENT_PIP_EVIDENCE"], !folder.isEmpty {
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let snapshot = try await child.takeSnapshot(configuration: nil)
            let bitmap = try #require(snapshot.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("document-chat.png"), options: .atomic)
        }

        pressClose(panel)
        try await wait { fixture.source.documentPiP.web == nil }
        try await wait {
            (try? await sourceWeb.evaluateJavaScript("window.pagehid === 1 && document.querySelector('#draft') === originalInput")) as? Bool == true
        }
        #expect(try await sourceWeb.evaluateJavaScript("documentPictureInPicture.window === null && liveWindow.closed") as? Bool == true)
        #expect(try await sourceWeb.evaluateJavaScript("document.querySelector('#draft').value") as? String == "kept draft reply")
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
        #expect(DocumentPiP.owner(of: child) == nil)
    }

    @Test func aLocalAppKitKeyOpensAPiPInAnOrdinaryTab() async throws {
        let fixture = try await makeFixture(automaticPopups: false)
        defer { fixture.close() }
        let source = requireNativeWebKitFixture(fixture.source, "DocumentPiPTests")
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        // An ordinary tab's normal policy: WebKit hands every window asked
        // for to Browser, which judges it (WindowGate, e2d0057b). The PiP
        // still needs the engine's own activation: the override is deleted
        // below and requestWindow refuses without it.
        #expect(source.configuration.preferences.javaScriptCanOpenWindowsAutomatically == true)
        #expect(!fixture.source.bench)
        _ = try await source.evaluateJavaScript("""
            delete navigator.userActivation;
            const button = document.createElement('button'); button.id = 'openPiP';
            button.textContent = 'Open PiP';
            button.style.cssText = 'position:absolute;left:40px;top:90px;width:160px;height:40px';
            setTimeout(() => { window.activationBeforeClick = window.readActivationState(); }, 0);
            button.addEventListener('keydown', async event => {
              if (event.code !== 'Space') return;
              event.preventDefault();
              window.clickedTrusted = event.isTrusted;
              window.activationOnClick = window.readActivationState();
              window.clickedActivated = navigator.userActivation?.isActive === true;
              window.openGestureArrived = true;
              try {
                window.liveWindow = await documentPictureInPicture.requestWindow({width:420,height:280});
                window.liveWindow.addEventListener('pagehide', () => {
                  document.querySelector('#home').append(window.chatNode);
                }, {once:true});
                window.liveWindow.document.body.append(window.chatNode);
              } catch (error) { window.openError = error.name + ': ' + error.message; }
              window.openClicked = true;
            });
            document.body.append(button); true
            """)
        try await pressSpace("#openPiP", in: source)
        try await wait {
            (try? await source.evaluateJavaScript("window.openGestureArrived === true")) as? Bool == true
        }
        let trustedGesture = try await source.evaluateJavaScript("window.clickedTrusted && window.clickedActivated") as? Bool == true
        if !trustedGesture {
            await diagnose(fixture, reason: "AppKit key did not record both trust and native activation", before: ids)
        }
        try #require(trustedGesture,
                     "The fixture must receive a trusted AppKit key with native activation")
        try await wait {
            (try? await source.evaluateJavaScript("window.openClicked === true")) as? Bool == true
        }
        let error = try await source.evaluateJavaScript("window.openError || ''") as? String
        try #require(error == "", "Native fixture key failed: \(error ?? "no result")")
        let child = try #require(fixture.source.documentPiP.web)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await source.evaluateJavaScript("liveWindow.opener === window && liveWindow.document.querySelector('#draft') === originalInput && originalInput.ownerDocument === liveWindow.document") as? Bool == true)
        #expect(child.window === fixture.source.documentPiP.panel)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test(arguments: [false, true])
    func theChildCloseShortcutAndMenuLeaveTheSourceTabAlive(usingMenu: Bool) async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        let sourceWeb = requireNativeWebKitFixture(fixture.source, "DocumentPiPTests")
        let child = try await open(fixture)
        let document = fixture.source.documentPiP
        let panel = try #require(document.panel)

        // Events are passed straight to this document's dispatcher; no
        // application-wide key delivery or user-window menu action occurs.
        let sourceClose = try key("w", code: 13, flags: .command, in: fixture.window)
        #expect(sourceClose.window === fixture.window)
        #expect(!document.take(sourceClose))
        let typing = try key("a", code: 0, flags: [], in: panel)
        #expect(typing.window === panel)
        #expect(!document.take(typing))
        #expect(document.web === child && !fixture.source.gone)

        panel.makeKeyAndOrderFront(nil)
        try #require(NSApp.keyWindow === panel)
        if usingMenu {
            #expect(DocumentPiP.closeKeyWindow())
        } else {
            let close = try key("w", code: 13, flags: .command, in: panel)
            #expect(close.window === panel)
            #expect(document.take(close))
        }
        try await wait { document.web == nil }
        try await wait {
            (try? await sourceWeb.evaluateJavaScript("window.pagehid === 1 && document.querySelector('#draft') === originalInput")) as? Bool == true
        }
        #expect(!fixture.source.gone)
        #expect(fixture.source.built === sourceWeb)
        #expect(try await sourceWeb.evaluateJavaScript("documentPictureInPicture.window === null && liveWindow.closed && originalInput.value === 'kept draft'") as? Bool == true)
        #expect(DocumentPiP.owner(of: child) == nil)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func returningToAParkedSourceRevealsItsRowBeforeSelectingIt() async throws {
        try #require(Store.testing, "This fixture must use Store's isolated test world")
        let fixture = try await makeFixture(automaticPopups: false)
        let storedSpaces = Store.settings.object(forKey: "spaces")
        let spacesFile = Store.file("spaces.json"), spacesData = try? Data(contentsOf: spacesFile)
        let enabled = fixture.browser.prefs.usesSpaces
        let home = UUID()
        defer {
            fixture.browser.prefs.usesSpaces = enabled
            Store.settings.set(storedSpaces, forKey: "spaces")
            if let spacesData { try? spacesData.write(to: spacesFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: spacesFile) }
            Store.settings.removeObject(forKey: "window.\(fixture.windowID.uuidString).space")
            try? FileManager.default.removeItem(at: Store.file("session-window-\(fixture.windowID.uuidString)-\(home.uuidString).json"))
            Spaces.pageCounts[home] = nil
            fixture.close()
        }
        requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let child = try await open(fixture)
        let document = fixture.source.documentPiP
        let panel = try #require(document.panel)
        let other = try #require(fixture.browser.tabs.first { $0 !== fixture.source })
        fixture.browser.prefs.usesSpaces = true
        fixture.browser.spaces.append(Space(id: home, name: "Document fixture", icon: "", ownSignIns: false))
        fixture.browser.lay([other])
        fixture.browser.activeID = other.id
        fixture.browser.parked[home] = Parked(tabs: [fixture.source], active: fixture.source.id)
        #expect(!fixture.browser.tabs.contains { $0 === fixture.source })
        #expect(fixture.browser.activeID == other.id)

        let button = try #require(panel.titlebarAccessoryViewControllers
            .flatMap { $0.view.subviews }.compactMap { $0 as? NSButton }
            .first { $0.title == "Back to Tab" })
        press(button)
        try await wait { document.web == nil }
        try await wait {
            (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.pagehid === 1 && document.querySelector('#draft') === originalInput")) as? Bool == true
        }
        #expect(fixture.browser.spaceID == home)
        #expect(fixture.browser.tabs.contains { $0 === fixture.source })
        #expect(fixture.browser.active === fixture.source)
        #expect(fixture.browser.tabs.contains { $0.id == fixture.browser.activeID })
        #expect(fixture.browser.parked[home] == nil)
        #expect(!fixture.source.gone)
        #expect(DocumentPiP.owner(of: child) == nil)
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("document === originalDocument && originalInput.value === 'kept draft'") as? Bool == true)
    }

    @Test func nativeAndLocallyClickedResizesReachTheChildViewport() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let child = try await open(fixture)
        let panel = try #require(fixture.source.documentPiP.panel)
        try #require((panel.screen?.visibleFrame.width ?? 0) >= 700)
        try #require((panel.screen?.visibleFrame.height ?? 0) >= 500)
        panel.setContentSize(NSSize(width: 560, height: 360))
        try await wait {
            (try? await child.evaluateJavaScript("[innerWidth,innerHeight]")) as? [Int] == [560, 360]
        }
        // Public native WebKit evaluation itself grants an engine gesture.
        // Schedule from the source instead, let transient activation expire,
        // and avoid native child evaluation until the forged call has ended.
        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("""
            window.forgedResizeDone = false;
            window.liveWindow.setTimeout(() => {
              Object.defineProperty(window.liveWindow.navigator, 'userActivation', {
                configurable:true,value:{isActive:true,hasBeenActive:true}
              });
              window.liveWindow.resizeTo(510,330);
              window.forgedResizeDone = true;
            }, 5500); true
            """)
        try await Task.sleep(for: .milliseconds(6000))
        try await wait {
            (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.forgedResizeDone === true")) as? Bool == true
        }
        #expect(panel.contentView?.bounds.size == NSSize(width: 560, height: 360))
        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("delete window.liveWindow.navigator.userActivation; true")
        _ = try await child.evaluateJavaScript("""
            for (const [id, top, relative] of [['resizeTo',70,false],['resizeBy',120,true]]) {
              const button = document.createElement('button'); button.id = id; button.textContent = id;
              button.style.cssText = 'position:absolute;left:40px;top:' + top + 'px;width:140px;height:36px';
              button.addEventListener('keydown', event => {
                if (event.code !== 'Space') return;
                event.preventDefault();
                window.clickedTrusted = event.isTrusted;
                window.clickedActivated = navigator.userActivation?.isActive === true;
                if (relative) resizeBy(30,20); else resizeTo(510,330);
                window.lastResize = id;
              });
              document.body.append(button);
            } true
            """)
        try await pressSpace("#resizeTo", in: child)
        try await wait {
            (try? await child.evaluateJavaScript("[innerWidth,innerHeight]")) as? [Int] == [510, 330]
        }
        #expect(try await child.evaluateJavaScript("window.clickedTrusted && window.clickedActivated && window.lastResize === 'resizeTo'") as? Bool == true)
        try await pressSpace("#resizeBy", in: child)
        try await wait {
            (try? await child.evaluateJavaScript("[innerWidth,innerHeight]")) as? [Int] == [540, 350]
        }
        #expect(try await child.evaluateJavaScript("window.clickedTrusted && window.clickedActivated && window.lastResize === 'resizeBy'") as? Bool == true)
        #expect(panel.contentView?.bounds.size == NSSize(width: 540, height: 350))
    }

    @Test func replacementRestoresTheOldDocumentsNodesBeforeTheNewPromiseResolves() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let first = try await open(fixture)
        let firstOwner = fixture.source.documentPiP
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").callAsyncJavaScript("""
            window.oldWindow = window.liveWindow;
            window.liveWindow = await documentPictureInPicture.requestWindow({width:430,height:290});
            window.restoredBeforeReplacement = window.pagehid === 1 &&
              originalInput.ownerDocument === document && document.querySelector('#draft') === originalInput;
            window.liveWindow.addEventListener('pagehide', () => {
              document.querySelector('#home').append(window.chatNode);
            }, {once:true});
            window.liveWindow.document.body.append(window.chatNode);
            return true;
            """, contentWorld: .page)
        let second = try #require(fixture.source.documentPiP.web)
        #expect(second !== first)
        try await wait { firstOwner.web == nil }
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.restoredBeforeReplacement && oldWindow.closed && liveWindow === documentPictureInPicture.window") as? Bool == true)
        try await wait {
            (try? await second.evaluateJavaScript("document.querySelector('#draft')?.value === 'kept draft'")) as? Bool == true
        }
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func writingChildHTMLKeepsNativeResizeAndReplacementRestorationWorking() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let first = try await open(fixture)
        let firstOwner = fixture.source.documentPiP
        let panel = try #require(firstOwner.panel)
        try #require((panel.screen?.visibleFrame.width ?? 0) >= 700)
        try #require((panel.screen?.visibleFrame.height ?? 0) >= 500)
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID

        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("""
            // Sites write the child shell before moving their live controls.
            // Keep the form outside document.open's listener-clearing subtree.
            document.querySelector('#home').append(window.chatNode);
            const previous = window.liveWindow.document;
            previous.open();
            previous.write('<!doctype html><title>Rewritten chat</title><body><button id="rewriteResize" style="position:absolute;left:40px;top:90px;width:160px;height:40px">Resize</button></body>');
            previous.close();
            window.rewriteDocumentPreserved = previous === window.liveWindow.document;
            window.liveWindow.document.body.append(window.chatNode);
            window.rewrittenSiteHides = 0;
            window.liveWindow.addEventListener('pagehide', () => {
              window.rewrittenSiteHides++;
              document.querySelector('#home').append(window.chatNode);
            }, {once:true}); true
            """)
        try await wait {
            (try? await first.evaluateJavaScript("document.title === 'Rewritten chat' && document.querySelector('#draft')?.value === 'kept draft'")) as? Bool == true
        }
        // Let the document-root mutation observers rearm after the write.
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("rewriteDocumentPreserved && liveWindow.document.querySelector('#draft') === originalInput && originalInput.ownerDocument === liveWindow.document") as? Bool == true)
        _ = try await first.evaluateJavaScript("document.querySelector('button[type=submit]').click(); true")
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.sent === 1 && window.lastSent === 'kept draft'") as? Bool == true)

        _ = try await first.evaluateJavaScript("""
            document.querySelector('#rewriteResize').addEventListener('keydown', event => {
              if (event.code !== 'Space') return;
              event.preventDefault();
              window.rewriteClickTrusted = event.isTrusted;
              window.rewriteClickActivated = navigator.userActivation?.isActive === true;
              resizeTo(520,340);
            }); true
            """)
        try await pressSpace("#rewriteResize", in: first)
        try await wait {
            (try? await first.evaluateJavaScript("[innerWidth,innerHeight]")) as? [Int] == [520, 340]
        }
        #expect(try await first.evaluateJavaScript("window.rewriteClickTrusted && window.rewriteClickActivated") as? Bool == true)

        _ = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").callAsyncJavaScript("""
            window.oldWindow = window.liveWindow;
            window.liveWindow = await documentPictureInPicture.requestWindow({width:430,height:290});
            window.rewrittenRestoredBeforeReplacement = window.rewrittenSiteHides === 1 &&
              document.querySelector('#draft') === originalInput && originalInput.ownerDocument === document;
            window.liveWindow.document.body.append(window.chatNode);
            window.liveWindow.addEventListener('pagehide', () => {
              document.querySelector('#home').append(window.chatNode);
            }, {once:true}); return true;
            """, contentWorld: .page)
        let second = try #require(fixture.source.documentPiP.web)
        #expect(second !== first)
        try await wait { firstOwner.web == nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("rewrittenRestoredBeforeReplacement && oldWindow.closed && liveWindow.document.querySelector('#draft') === originalInput && originalInput.ownerDocument === liveWindow.document") as? Bool == true)
        #expect(try await second.evaluateJavaScript("document.querySelector('#draft')?.value === 'kept draft'") as? Bool == true)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func attemptingChildTopLevelNavigationClosesAndRestoresTheDocument() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let child = try await open(fixture)
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        let nested = try await child.callAsyncJavaScript("""
            try { await documentPictureInPicture.requestWindow(); return 'opened'; }
            catch (error) { return error.name; }
            """, contentWorld: .page) as? String
        #expect(nested == "NotAllowedError")
        // An in-document anchor must retain the same live nodes and panel.
        _ = try await child.evaluateJavaScript("window.location.hash = 'chat-section'; true")
        try await wait {
            (try? await child.evaluateJavaScript("location.hash === '#chat-section'")) as? Bool == true
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(fixture.source.documentPiP.web === child)
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("originalInput.ownerDocument === liveWindow.document && liveWindow.document.querySelector('#draft') === originalInput") as? Bool == true)
        // A data URL requires no server/network, but is a new top-level
        // document and must pass through the native navigation policy.
        _ = try await child.evaluateJavaScript("window.location.href = 'data:text/html,<title>Escaped</title><body>Escaped</body>'; true")
        try await wait { fixture.source.documentPiP.web == nil }
        try await wait {
            (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.pagehid === 1 && document.querySelector('#draft') === originalInput")) as? Bool == true
        }
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("documentPictureInPicture.window === null && liveWindow.closed && originalInput.value === 'kept draft'") as? Bool == true)
        #expect(DocumentPiP.owner(of: child) == nil)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func anInactiveSourceStaysAwakeWhileItsDocumentIsOut() async throws {
        let fixture = try await makeFixture(automaticPopups: false)
        defer { fixture.close() }
        requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        _ = try await open(fixture)
        try await wait { !fixture.source.loading }
        // The ordinary source cannot win the earlier "a bench tab" reason.
        fixture.browser.activeID = try #require(fixture.browser.tabs.first { $0 !== fixture.source }?.id)
        #expect(fixture.browser.awake(because: fixture.source) == "its document is out")
    }

    @Test func aNewSourceDocumentClosesTheChildWithoutChangingTabs() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        let child = try await open(fixture)
        requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").loadHTMLString("<!doctype html><title>Next document</title><body>Next</body>",
                                         baseURL: URL(string: "https://document-pip.test/next"))
        try await wait { fixture.source.documentPiP.web == nil }
        try await wait {
            (try? await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("document.title === 'Next document'")) as? Bool == true
        }
        #expect(DocumentPiP.owning(page: child) == nil)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func requestsWithoutUserActivationRejectAndDoNotOpenTabs() async throws {
        let fixture = try await makeFixture(parserRequest: true)
        defer { fixture.close() }
        let ids = fixture.browser.tabs.map(\.id), active = fixture.browser.activeID
        // Read the parser's recorded attempt; invoking requestWindow from
        // evaluateJavaScript/callAsyncJavaScript would grant an engine gesture.
        #expect(try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.noGestureActivation") as? Bool == false)
        let result = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").evaluateJavaScript("window.noGestureResult") as? String
        #expect(result == "NotAllowedError")
        #expect(fixture.source.documentPiP.web == nil)
        #expect(fixture.browser.tabs.map(\.id) == ids)
        #expect(fixture.browser.activeID == active)
    }

    @Test func dimensionsMustBeAPositivePair() async throws {
        let fixture = try await makeFixture()
        defer { fixture.close() }
        try await allowFixtureGesture(on: requireNativeWebKitFixture(fixture.source, "DocumentPiPTests"))
        let results = try await requireNativeWebKitFixture(fixture.source, "DocumentPiPTests").callAsyncJavaScript("""
            const invalid = [{width:400}, {height:300}, {width:0,height:300},
              {width:400,height:0}, {width:-1,height:300}, {width:400,height:-1},
              {width:Infinity,height:300}, {width:400,height:NaN}];
            const results = [];
            for (const options of invalid) {
              try { const child = await documentPictureInPicture.requestWindow(options);
                child.close(); results.push('opened'); }
              catch (error) { results.push(error.name); }
            }
            return results;
            """, contentWorld: .page) as? [String]
        let rejected = try #require(results)
        #expect(rejected.count == 8)
        #expect(rejected.allSatisfy { ["RangeError", "TypeError"].contains($0) })
        #expect(fixture.source.documentPiP.web == nil)
        #expect(fixture.browser.tabs.count == 2)
    }

    @Test func insecureDocumentsAndChildFramesCannotRequestAPiP() async throws {
        // Explicitly install the product script in every frame for this API
        // boundary check; no Browser delegates or external site are involved.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: DocumentPiPScript.source,
            injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        defer { web.stopLoading() }
        web.loadHTMLString("<!doctype html><title>Insecure</title><body>Insecure</body>",
                           baseURL: URL(string: "http://insecure.document-pip.test/"))
        try await wait {
            (try? await web.evaluateJavaScript("document.title === 'Insecure' && document.readyState === 'complete'")) as? Bool == true
        }
        #expect(try await web.evaluateJavaScript("window.isSecureContext") as? Bool == false)
        let insecure = try await web.callAsyncJavaScript("""
            if (!window.documentPictureInPicture) return 'unavailable';
            Object.defineProperty(navigator, 'userActivation', {configurable:true,value:{isActive:true}});
            try { await documentPictureInPicture.requestWindow(); return 'opened'; }
            catch (error) { return error.name; }
            """, contentWorld: .page) as? String
        #expect(insecure == "unavailable" || insecure == "NotAllowedError")

        web.loadHTMLString("<!doctype html><title>Frame</title><iframe srcdoc='<p>Child</p>'></iframe>",
                           baseURL: URL(string: "https://document-pip.test/frame"))
        try await wait {
            (try? await web.evaluateJavaScript("document.title === 'Frame' && frames.length === 1 && frames[0].document.readyState === 'complete'")) as? Bool == true
        }
        let frame = try await web.callAsyncJavaScript("""
            const child = frames[0];
            if (!child.documentPictureInPicture) return 'unavailable';
            Object.defineProperty(child.navigator, 'userActivation', {configurable:true,value:{isActive:true}});
            try { await child.documentPictureInPicture.requestWindow(); return 'opened'; }
            catch (error) { return error.name; }
            """, contentWorld: .page) as? String
        #expect(frame == "unavailable" || frame == "NotAllowedError")
    }
}

