import AppKit
import ObjectiveC
import Testing
import WebKit
@testable import Fast

/// The native callback with an engine-created action. Only that object's
/// public request getter is replaced; no global WebKit method is swizzled.
@MainActor @Suite(.serialized)
struct PopupNativeRequestTests {
    private final class Capture: NSObject, WKNavigationDelegate {
        var action: WKNavigationAction?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            self.action = action
            decisionHandler(.cancel)
        }
    }

    private final class Listener: NSObject, PageEvents {
        var finished = false
        var popup: PagePopup?
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .finished = event { finished = true }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        var reply: (@MainActor (UUID?) -> Void)?
        func page(_ page: any PageHandle, open popup: PagePopup,
                  reply: @escaping @MainActor (UUID?) -> Void) {
            self.popup = popup
            self.reply = reply
        }
    }

    private final class Getter {
        let action: WKNavigationAction
        let original: AnyClass
        let replacement: AnyClass
        let implementation: IMP
        private final class State {
            var value: NSObject?
            var reads = 0
            init(_ value: NSObject?) { self.value = value }
        }
        private let state: State
        var value: NSObject? {
            get { state.value }
            set { state.value = newValue }
        }
        var reads: Int { state.reads }

        init(_ action: WKNavigationAction, value: NSObject?) throws {
            self.action = action
            let state = State(value)
            self.state = state
            original = try #require(object_getClass(action))
            let selector = #selector(getter: WKNavigationAction.request)
            let method = try #require(class_getInstanceMethod(original, selector))
            replacement = try #require(objc_allocateClassPair(original, "YabPopupRequest_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""), 0))
            // State holds no action or page; the test restores the class below.
            let getter: @convention(block) (AnyObject) -> AnyObject? = { _ in
                MainActor.assumeIsolated {
                    state.reads += 1
                    return state.value
                }
            }
            implementation = imp_implementationWithBlock(getter)
            guard class_addMethod(replacement, selector, implementation, method_getTypeEncoding(method)) else {
                imp_removeBlock(implementation)
                objc_disposeClassPair(replacement)
                throw FixtureError.getter
            }
            objc_registerClassPair(replacement)
            object_setClass(action, replacement)
        }

        func restore() {
            object_setClass(action, original)
            objc_disposeClassPair(replacement)
            imp_removeBlock(implementation)
        }
    }

    private enum FixtureError: Error { case getter }

    private func fixture() async throws -> (PageView, WKNavigationAction) {
        try #require(Store.testing && Store.world != nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = PageView(frame: .zero, configuration: configuration)
        let capture = Capture()
        view.navigationDelegate = capture
        view.load(URLRequest(url: URL(string: "about:blank#native-popup-fixture")!))
        defer { view.navigationDelegate = view.navigationEvents }
        for _ in 0..<200 where capture.action == nil { try await Task.sleep(for: .milliseconds(20)) }
        return (view, try #require(capture.action))
    }

    @Test(arguments: [false, true])
    func absentOrWrongNativeRequestCancelsOnceBeforeMutatingThePopup(wrongClass: Bool) async throws {
        let (view, action) = try await fixture()
        let getter = try Getter(action, value: wrongClass ? NSString(string: "not a request") : nil)
        let listener = Listener(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let controller = configuration.userContentController
        view.navigationEvents.listener = listener
        defer { getter.restore(); view.stopLoading(); view.navigationEvents.listener = nil }
        var answers = 0
        view.navigationEvents.createPopup(view, configuration: configuration, action: action,
                                         features: WKWindowFeatures()) { child in
            answers += 1
            #expect(child == nil)
        }
        #expect(answers == 1 && getter.reads == 1)
        #expect(listener.popup == nil && listener.reply == nil)
        #expect(view.navigationEvents.popups.isEmpty)
        #expect(configuration.userContentController === controller)
    }

    @Test(arguments: ["about:blank", "https://popup.fixture.invalid/oauth", "missing"])
    func aValidNativeSnapshotKeepsBlankMissingAndHTTPSURLsWithoutReadingTheGetterAgain(destination: String) async throws {
        let (view, action) = try await fixture()
        let native = NSMutableURLRequest(url: URL(string: "about:blank")!)
        native.url = destination == "missing" ? nil : URL(string: destination)!
        native.httpMethod = "POST"
        native.httpBody = Data("popup-body".utf8)
        native.setValue("kept", forHTTPHeaderField: "X-Popup-Fixture")
        let getter = try Getter(action, value: native)
        let listener = Listener(), configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = view.configuration.websiteDataStore
        let controller = configuration.userContentController
        view.navigationEvents.listener = listener
        defer { listener.reply?(nil); getter.restore(); view.stopLoading(); view.navigationEvents.listener = nil }
        var answers = 0
        view.navigationEvents.createPopup(view, configuration: configuration, action: action,
                                         features: WKWindowFeatures()) { child in
            answers += 1
            #expect(child == nil)
        }
        let popup = try #require(listener.popup), reply = try #require(listener.reply)
        #expect(getter.reads == 1 && answers == 0)
        #expect(popup.action.request.url == native.url)
        #expect(popup.action.request.httpMethod == "POST")
        #expect(popup.action.request.httpBody == Data("popup-body".utf8))
        #expect(popup.action.request.value(forHTTPHeaderField: "X-Popup-Fixture") == "kept")
        #expect(popup.action.kind.rawValue == action.navigationType.rawValue)
        #expect(popup.action.targetIsMainFrame == action.targetFrame?.isMainFrame)
        #expect(configuration.userContentController !== controller)
        #expect(view.navigationEvents.popups[popup.id]?.configuration === configuration)
        // The copied request cannot change while the listener delays its answer.
        getter.value = nil
        native.setValue("changed", forHTTPHeaderField: "X-Popup-Fixture")
        #expect(popup.action.request.value(forHTTPHeaderField: "X-Popup-Fixture") == "kept")
        reply(nil); reply(UUID())
        #expect(answers == 1 && getter.reads == 1 && view.navigationEvents.popups.isEmpty)
    }

    @Test func realBlankPopupKeepsDelayedReplyOpenerAndSuppliedConfiguration() async throws {
        try #require(Store.testing && Store.world != nil)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = PageView(frame: .zero, configuration: configuration), listener = Listener()
        view.events = listener
        var child: Fast.Tab?
        defer { listener.reply?(nil); child?.close(); view.stopLoading(); view.events = nil }
        view.loadHTMLString("<title>Owned popup fixture</title>", baseURL: nil)
        for _ in 0..<300 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        let opening = Task { try await view.run("window.child = window.open('about:blank', 'owned-popup', 'width=420,height=300'); child !== null && child.opener === window") }
        for _ in 0..<300 where listener.reply == nil { try await Task.sleep(for: .milliseconds(20)) }
        let popup = try #require(listener.popup), reply = try #require(listener.reply)
        let supplied = try #require(view.navigationEvents.popups[popup.id]?.configuration)
        #expect(popup.width == 420 && popup.height == 300)
        #expect(popup.action.request.url?.absoluteString == "about:blank")
        child = try #require(view.webKitPopupTab(popup.id, bench: true))
        let popupTab = try #require(child), page = requireNativeWebKitFixture(popupTab, "PopupNativeRequestTests")
        #expect(page.configuration.websiteDataStore === view.configuration.websiteDataStore)
        #expect(page.configuration.userContentController === supplied.userContentController)
        #expect(page.configuration.userContentController !== view.configuration.userContentController)
        #expect(SiteProcesses.related(of: page.configuration) === view)
        reply(popupTab.id); reply(nil)
        #expect(try await opening.value as? Bool == true)
        #expect(try await page.run("window.opener !== null") as? Bool == true)
        #expect(view.navigationEvents.popups.isEmpty)
    }

}
