import AppKit
import Testing
import YabCoreClient
@testable import Fast

@MainActor @Suite(.serialized)
struct ChromiumLoadFailureTests {
    @Test(arguments: ["page.loadError", "page.oauthRedirect"])
    func extensionOAuthCallbacksDoNotFailOrRetry(event: String) throws {
        let callback = try #require(URL(string: "https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/?code=fixture&state=original"))
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "oauth-test-" + UUID().uuidString
        page.adoptRemote(remote); page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        page.receive(YabCoreEvent(name: event, params: ["tab": .string(remote),
            "code": .number(-105), "message": .string("net::ERR_NAME_NOT_RESOLVED"),
            "url": .string(callback.absoluteString)]))
        #expect(listener.failures.isEmpty)
        #expect(page.diagnosticFailure == nil)
        #expect(!page.isLoading)
        #expect(page.url == callback)
        var retry = DNSRetry()
        retry.begin(URLRequest(url: callback))
        retry.wait(code: -105, failed: callback, domain: "net")
        #expect(!retry.pending)
    }

    @Test func onlyReservedExtensionCallbackOriginsAreSpecial() {
        let id = "fkmaohpngenfoccdgceedjkfhkdcohmg"
        for value in ["https://\(id).chromiumapp.org/", "https://\(id).chromiumapp.org:443/path?code=a#state=b"] {
            #expect(ChromiumOAuthRedirect.matches(URL(string: value)!))
        }
        for value in ["http://\(id).chromiumapp.org/", "https://\(id).chromiumapp.org:8443/",
                      "https://\(id).chromiumapp.org.evil.test/", "https://www.\(id).chromiumapp.org/",
                      "https://bad.chromiumapp.org/", "https://\(id).chromiumapp.org@evil.test/",
                      "https://user@\(id).chromiumapp.org/", "https://chromiumapp.org/"] {
            #expect(!ChromiumOAuthRedirect.matches(URL(string: value)!))
        }
    }

    @Test func anAbortedOAuthLoadCannotReplaceANewerAddress() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "oauth-abort-" + UUID().uuidString
        page.adoptRemote(remote); page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        let previous = page.url
        page.receive(YabCoreEvent(name: "page.loadError", params: ["tab": .string(remote),
            "code": .number(-3), "message": .string("net::ERR_ABORTED"),
            "url": .string("https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/?code=old")]))
        #expect(page.url == previous)
        #expect(listener.failures.isEmpty)
    }

    @Test func chromiumMessagesAndDiagnosticNamesUseTheirOwnDomain() {
        for (code, name, message) in [
            (-106, "ERR_INTERNET_DISCONNECTED", "You’re offline"),
            (-105, "ERR_NAME_NOT_RESOLVED", "Nothing answers at this address"),
            (-101, "ERR_CONNECTION_RESET", "The connection was interrupted"),
            (-102, "ERR_CONNECTION_REFUSED", "The site won’t accept connections"),
            (-202, "ERR_CERT_AUTHORITY_INVALID", "Can’t connect securely")
        ] {
            #expect(PageLoadFailure.message(domain: "net", code: code) == message)
            let fields = LoadFailureLog.fields(engine: .chromium, domain: "net", code: code,
                host: "example.test", name: nil, version: "test")
            #expect(fields["name"] as? String == "net::" + name)
            #expect(PageLoadFailure.message(domain: "Other", code: code) == "The page couldn’t load")
        }
        #expect(PageLoadFailure.message(domain: "net", code: -9999) == "The page couldn’t load")
        #expect(PageLoadFailure.message(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet) == "You’re offline")
    }

    private final class Listener: PageEvents {
        var failures: [NSError] = []
        func page(_ page: any PageHandle, navigation event: PageNavigationEvent) {
            if case .failed(_, let error, _) = event { failures.append(error as NSError) }
        }
        func page(_ page: any PageHandle, decide response: PageDocumentResponse,
                  reply: @escaping @MainActor (PagePolicy) -> Void) { reply(.allow) }
    }

    @Test func aRejectedFeatureAfterAttachmentDoesNotFailTheDocumentOrHideANetError() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "load-test-" + UUID().uuidString
        page.adoptRemote(remote); page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        let errors: [Error] = [YabCoreError.remote("Session with given id not found."), YabCoreError.timeout]
        for error in errors {
            page.queuedOperationFailed(error, navigation: false, request: "input.send")
            #expect(listener.failures.isEmpty)
            #expect(page.diagnosticFailure == nil)
            #expect((page.surfaceState["scriptAttachmentFailure"] as? String)?.hasPrefix("input.send:") == true)
        }
        page.receive(YabCoreEvent(name: "page.loadError", params: ["tab": .string(remote),
            "code": .number(-102), "message": .string("net::ERR_CONNECTION_REFUSED"),
            "url": .string("https://unreachable.invalid/")]))
        #expect(listener.failures.count == 1)
        #expect(listener.failures.first?.code == -102)
    }

    @Test func rejectedNavigationAndEndpointCreationStillFail() {
        for navigation in [false, true] {
            let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
            let remote = "load-test-" + UUID().uuidString
            if navigation { page.adoptRemote(remote) }
            page.events = listener
            page.queuedOperationFailed(YabCoreError.remote("Tab closed"), navigation: navigation, request: "tab.navigate")
            #expect(listener.failures.count == 1)
            #expect(page.diagnosticFailure != nil)
            page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close()
        }
    }

    @Test func genericCodeOneIsRemoteNotANetErrorOrTimeout() {
        #expect((YabCoreError.remote("rejected") as NSError).code == 1)
        #expect((YabCoreError.timeout as NSError).code == 4)
        #expect((YabCoreError.disconnected as NSError).code == 3)
    }

    @Test func aScriptSessionEndingDuringRedirectDoesNotFailTheDocument() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "load-test-" + UUID().uuidString
        page.adoptRemote(remote)
        page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        page.receive(YabCoreEvent(name: "script.error", params: ["tab": .string(remote),
            "message": .string("Session with given id not found.")]))
        #expect(listener.failures.isEmpty)
        #expect(page.diagnosticFailure == nil)
        #expect(page.surfaceState["scriptAttachmentFailure"] as? String == "Session with given id not found.")
    }

    @Test func anAbortIsIgnoredButARealNetworkFailureKeepsItsCodeAndHost() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "load-test-" + UUID().uuidString
        page.adoptRemote(remote); page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        func send(_ code: Int, _ name: String) {
            page.receive(YabCoreEvent(name: "page.loadError", params: ["tab": .string(remote),
                "code": .number(Double(code)), "message": .string(name),
                "url": .string("https://unreachable.invalid/?secret=never-upload")]))
        }
        page.failed(CancellationError())
        #expect(listener.failures.isEmpty)
        #expect(page.diagnosticFailure == nil)
        send(-3, "net::ERR_ABORTED")
        #expect(listener.failures.isEmpty)
        send(-105, "net::ERR_NAME_NOT_RESOLVED")
        #expect(listener.failures.count == 1)
        #expect(listener.failures.first?.domain == "net")
        #expect(listener.failures.first?.code == -105)
        #expect(listener.failures.first?.userInfo["netErrorName"] as? String == "net::ERR_NAME_NOT_RESOLVED")
    }

    @Test func transientGETFailureIsReportedWhileChromeOwnsRecovery() {
        for code in [-7, -101, -102, -105, -106, -118, -324] {
            let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
            let remote = "retry-test-" + UUID().uuidString
            let url = URL(string: "https://recover.test/")!
            page.adoptRemote(remote); page.events = listener
            page.acceptNavigation(URLRequest(url: url))
            page.receive(YabCoreEvent(name: "page.loadError", params: ["tab": .string(remote),
                "code": .number(Double(code)), "message": .string("transient"), "url": .string(url.absoluteString)]))
            #expect(listener.failures.count == 1)
            #expect(listener.failures.first?.code == code)
            page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close()
        }
    }

    @Test func transientFormFailureIsReportedWithoutReplay() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab), listener = Listener()
        let remote = "post-test-" + UUID().uuidString
        let url = URL(string: "https://recover.test/")!
        page.adoptRemote(remote); page.events = listener
        defer { page.retire(call: false, pictureInPicture: false); ChromiumProcess.shared.detach(remote); tab.close() }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        page.acceptNavigation(request)
        page.receive(YabCoreEvent(name: "page.loadError", params: ["tab": .string(remote),
            "code": .number(-101), "message": .string("reset"), "url": .string(url.absoluteString)]))
        #expect(listener.failures.count == 1)
    }
}
