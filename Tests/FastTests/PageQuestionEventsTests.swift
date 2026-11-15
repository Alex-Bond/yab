import AppKit
import Testing
import WebKit
@testable import Fast

@MainActor @Suite(.serialized)
struct PageQuestionEventsTests {
    private class Listener: NSObject, PageEvents {
        var origin: PageOrigin?
        var capture: PageCapture?
        var permission: (@MainActor (PagePermission) -> Void)?
        var notification: (@MainActor (Bool) -> Void)?
        var authentication: PageAuthentication?
        var authReply: (@MainActor (PageAuthenticationReply) -> Void)?
        var rejected: PageCertificate?
        var ends: [PageEnd?] = []
        var closed = 0

        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) { }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
        func page(_ page: any PageHandle, capture type: PageCapture, origin: PageOrigin,
                  reply: @escaping @MainActor (PagePermission) -> Void) {
            self.origin = origin; capture = type; permission = reply
        }
        func page(_ page: any PageHandle, locate origin: PageOrigin,
                  reply: @escaping @MainActor (PagePermission) -> Void) { self.origin = origin; permission = reply }
        func page(_ page: any PageHandle, notify origin: PageOrigin,
                  reply: @escaping @MainActor (Bool) -> Void) { self.origin = origin; notification = reply }
        func page(_ page: any PageHandle, authenticate challenge: PageAuthentication,
                  reply: @escaping @MainActor (PageAuthenticationReply) -> Void) {
            authentication = challenge; authReply = reply
        }
        func page(_ page: any PageHandle, rejected certificate: PageCertificate) { rejected = certificate }
        func page(_ page: any PageHandle, ended reason: PageEnd?) { ends.append(reason) }
        func pageClosed(_ page: any PageHandle) { closed += 1 }
        func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) { reply(nil) }
        func page(_ page: any PageHandle, dialog: PageDialog, reply: @escaping @MainActor (PageDialogReply) -> Void) { reply(.cancel) }
    }

    private final class Capture: NSObject, WKNavigationDelegate {
        var frame: WKFrameInfo?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            frame = WindowGate.source(action)
            decisionHandler(.cancel)
        }
    }

    private func fixture() async throws -> (PageView, WKFrameInfo) {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration()), capture = Capture()
        view.navigationDelegate = capture
        view.loadHTMLString("<p>Questions</p>", baseURL: URL(string: "https://seam.invalid:8443"))
        for _ in 0..<200 where capture.frame == nil { try await Task.sleep(for: .milliseconds(20)) }
        view.navigationDelegate = nil
        return (view, try #require(capture.frame))
    }

    @Test(arguments: [PagePermission.grant, .deny, .prompt])
    func mediaAndLocationWaitAndAnswerOnceAcrossListenerTransfer(answer: PagePermission) async throws {
        let (view, frame) = try await fixture()
        let listener = Listener(), next = Listener(), origin = frame.securityOrigin
        view.events = listener
        defer { view.stopLoading(); view.events = nil }
        #expect(view.navigationDelegate === view.navigationEvents && view.uiDelegate === view.navigationEvents)
        var answers: [WKPermissionDecision] = []
        view.navigationEvents.webView(view, requestMediaCapturePermissionFor: origin, initiatedByFrame: frame,
                                      type: .cameraAndMicrophone) { answers.append($0) }
        #expect(answers.isEmpty && listener.capture == .cameraAndMicrophone)
        #expect(listener.origin == PageOrigin(origin))
        let reply = try #require(listener.permission)
        view.events = next
        reply(answer); reply(.deny)
        #expect(answers == [answer.webKit] && next.permission == nil)
        view.navigationEvents.requestGeolocationPermission(view, origin: origin, frame: frame) { answers.append($0) }
        #expect(answers.count == 1 && next.origin == PageOrigin(origin))
        let located = try #require(next.permission)
        located(answer); located(.grant)
        #expect(answers == [answer.webKit, answer.webKit])
        var notifications: [Bool] = []
        view.navigationEvents.requestNotificationPermission(view, origin: origin) { notifications.append($0) }
        #expect(notifications.isEmpty)
        let notified = try #require(next.notification)
        notified(true); notified(false)
        #expect(notifications == [true])
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) { }
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) { }
        func cancel(_ challenge: URLAuthenticationChallenge) { }
    }

    private func challenge(method: String = NSURLAuthenticationMethodHTTPBasic, failures: Int = 1) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(host: "seam.invalid", port: 8443, protocol: "https", realm: "Private", authenticationMethod: method)
        return URLAuthenticationChallenge(protectionSpace: space,
            proposedCredential: URLCredential(user: "kept-user", password: "", persistence: .none),
            previousFailureCount: failures, failureResponse: nil, error: nil, sender: Sender())
    }

    @Test(arguments: [PageAuthenticationReply.performDefaultHandling, .cancel, .credential(user: "name", password: "secret")])
    func passwordAuthenticationCopiesMetadataAndHoldsExactlyOneReply(answer: PageAuthenticationReply) throws {
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration()), listener = Listener(), next = Listener()
        view.events = listener
        defer { view.events = nil }
        var answers: [URLSession.AuthChallengeDisposition] = []
        var credential: URLCredential?
        view.navigationEvents.webView(view, didReceive: challenge()) { answers.append($0); credential = $1 }
        #expect(answers.isEmpty)
        let metadata = try #require(listener.authentication)
        #expect(metadata.host == "seam.invalid" && metadata.realm == "Private" && metadata.scheme == "https")
        #expect(metadata.method == NSURLAuthenticationMethodHTTPBasic && metadata.previousFailureCount == 1)
        #expect(metadata.proposedUser == "kept-user" && metadata.proposedPasswordIsEmpty)
        let decoded = try JSONDecoder().decode(PageAuthentication.self, from: JSONEncoder().encode(metadata))
        #expect(decoded.host == metadata.host && decoded.proposedPasswordIsEmpty)
        let reply = try #require(listener.authReply)
        view.events = next
        reply(answer); reply(.cancel)
        #expect(answers.count == 1 && next.authentication == nil)
        switch answer {
        case .performDefaultHandling: #expect(answers == [.performDefaultHandling] && credential == nil)
        case .cancel: #expect(answers == [.cancelAuthenticationChallenge] && credential == nil)
        case .credential(let user, let password):
            #expect(answers == [.useCredential] && credential?.user == user && credential?.password == password)
            #expect(credential?.persistence == .forSession)
        }
    }

    private final class ProtectionSpace: URLProtectionSpace, @unchecked Sendable {
        let trust: SecTrust
        init(_ trust: SecTrust) {
            self.trust = trust
            super.init(host: "localhost", port: 8443, protocol: "https", realm: nil,
                       authenticationMethod: NSURLAuthenticationMethodServerTrust)
        }
        required init?(coder: NSCoder) { fatalError("Not used") }
        override var serverTrust: SecTrust? { trust }
    }

    @Test func installedAuthenticationRejectsAnUnapprovedChainAndDeliversOnlyCertificateValues() async throws {
        let trust = try CertificatePolicyTests.certificate()
        let view = PageView(frame: .zero, configuration: WKWebViewConfiguration()), listener = Listener()
        view.events = listener
        defer { view.events = nil }
        let challenge = URLAuthenticationChallenge(protectionSpace: ProtectionSpace(trust), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: Sender())
        var answers: [URLSession.AuthChallengeDisposition] = []
        view.navigationEvents.webView(view, didReceive: challenge) { answers.append($0); #expect($1 == nil) }
        for _ in 0..<500 where listener.rejected == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(answers == [.cancelAuthenticationChallenge])
        let certificate = try #require(listener.rejected)
        #expect(certificate.host == "localhost" && certificate.port == 8443)
        #expect(certificate.exception?.chain.isEmpty == false && !certificate.why.isEmpty && !certificate.names.isEmpty)
        let decoded = try JSONDecoder().decode(PageCertificate.self, from: JSONEncoder().encode(certificate))
        #expect(decoded.exception == certificate.exception && decoded.names == certificate.names)
        #expect(listener.authentication == nil)
    }

    @Test func missingListenerUsesEngineDefaultsAndDetachPreservesOtherDelegates() async throws {
        let (view, frame) = try await fixture()
        var auth: URLSession.AuthChallengeDisposition?
        view.navigationEvents.webView(view, didReceive: challenge()) { auth = $0; #expect($1 == nil) }
        #expect(auth == .performDefaultHandling)
        var permissions: [WKPermissionDecision] = []
        view.navigationEvents.webView(view, requestMediaCapturePermissionFor: frame.securityOrigin,
                                      initiatedByFrame: frame, type: .camera) { permissions.append($0) }
        view.navigationEvents.requestGeolocationPermission(view, origin: frame.securityOrigin, frame: frame) { permissions.append($0) }
        #expect(permissions == [.deny, .deny])
        let listener = Listener()
        weak var held: Listener?
        do { let temporary = Listener(); held = temporary; view.events = temporary }
        #expect(held == nil && view.events == nil)
        view.events = listener
        let other = LegacyUI()
        view.uiDelegate = other
        view.events = nil
        #expect(view.uiDelegate === other && view.navigationDelegate == nil)
    }

    private final class LegacyUI: Listener, WKUIDelegate, WKNavigationDelegate {
        var popups = 0
        var alerted = false
        var finished = false
        override func page(_ page: any PageHandle, open popup: PagePopup, reply: @escaping @MainActor (UUID?) -> Void) {
            popups += 1; reply(nil)
        }
        override func page(_ page: any PageHandle, dialog: PageDialog, reply: @escaping @MainActor (PageDialogReply) -> Void) {
            alerted = dialog.message == "forwarded"; reply(.accept(nil))
        }
        override func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .finished = event { finished = true }
        }
    }

    @Test func installedUIDelegateEmitsRealPopupAndDialogEvents() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = PageView(frame: .zero, configuration: configuration), listener = LegacyUI()
        view.installDelegates(listener)
        defer { view.stopLoading(); view.installDelegates(nil) }
        view.loadHTMLString("<p>Legacy UI</p>", baseURL: URL(string: "https://seam.invalid"))
        for _ in 0..<200 where !listener.finished { try await Task.sleep(for: .milliseconds(20)) }
        try #require(listener.finished)
        _ = try await view.run("alert('forwarded'); window.open('about:blank'); true")
        #expect(listener.alerted && listener.popups == 1)
        view.navigationEvents.webViewDidClose(view)
        view.navigationEvents.webViewWebContentProcessDidTerminate(view)
        view.navigationEvents._webView(view, webContentProcessDidTerminateWithReason: PageEnd.memory.rawValue)
        view.navigationEvents._webView(view, webContentProcessDidTerminateWithReason: 900)
        #expect(listener.closed == 1 && listener.ends.count == 3)
        #expect(listener.ends[0] == nil && listener.ends[1] == .memory && listener.ends[2] == .crash)
    }

    @Test func certificateRedirectUsesNativeFailingEndpointBeforeAddressCommit() throws {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        defer { browser.close(tab) }
        let initial = URL(string: "http://redirect.invalid/start")!
        let final = URL(string: "https://tls.invalid:8443/private")!
        tab.setAddressOptimistically(initial)
        let certificate = PageCertificate(host: "tls.invalid", port: 8443, exception: nil,
                                          why: "Rejected", names: "Chain", failingURL: final)
        browser.page(tab.page, rejected: certificate)
        #expect(tab.untrusted?.url == final)
        #expect(tab.address == final)
        #expect(try JSONDecoder().decode(PageCertificate.self, from: JSONEncoder().encode(certificate)).failingURL == final)
    }

    @Test func browserPasswordQuestionAndCertificatePageKeepTheirExistingDecisions() throws {
        let browser = Browser(windowID: UUID())
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        defer { browser.close(tab) }
        let page = tab.page
        var reply: PageAuthenticationReply?
        browser.page(page, authenticate: PageAuthentication(challenge())) { reply = $0 }
        #expect(reply == nil && tab.asks.first?.kind == .signIn("Private"))
        #expect(tab.asks.first?.failed == false && tab.asks.first?.text == "kept-user")
        tab.asks[0].text = "typed-user"; tab.asks[0].secret = "typed-password"; tab.asks[0].ticked = false
        browser.answer(tab, .yes(nil))
        #expect(reply == .credential(user: "typed-user", password: "typed-password"))
        browser.page(page, authenticate: PageAuthentication(challenge(failures: 2))) { reply = $0 }
        #expect(reply == .cancel && tab.asks.isEmpty)
        tab.setAddressOptimistically(URL(string: "https://seam.invalid:8443/private")!)
        let certificate = PageCertificate(host: "seam.invalid", port: 8443, exception: nil, why: "Rejected", names: "Chain")
        browser.page(page, rejected: certificate)
        #expect(tab.untrusted?.host == certificate.host && tab.untrusted?.why == "Rejected")
        tab.untrusted = nil
        browser.page(page, rejected: PageCertificate(host: "third-party.invalid", port: 8443, exception: nil, why: "Rejected", names: ""))
        #expect(tab.untrusted == nil)
        #expect(try JSONDecoder().decode(PageCertificate.self, from: JSONEncoder().encode(certificate)).port == 8443)
    }
}
