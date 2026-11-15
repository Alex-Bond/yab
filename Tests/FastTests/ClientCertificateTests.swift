import AppKit
import Testing
import WebKit
import YabCoreClient
@testable import Fast

@MainActor
@Suite(.serialized)
struct ClientCertificateTests {
    @Test func noWindowCannotPresentOrSelectAnIdentity() {
        var replies = 0
        ClientCertificates.choose(in: NSView(), host: "mtls.invalid", port: 443) { identity in
            #expect(identity == nil)
            replies += 1
        }
        #expect(replies == 1)
    }

    @Test func webKitClientChallengeIsHandledInsteadOfSilentlyDefaulted() {
        let view = WKWebView()
        let browser = Browser(windowID: UUID())
        defer { browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel() }
        let space = URLProtectionSpace(host: "mtls.invalid", port: 443, protocol: "https", realm: nil,
                                       authenticationMethod: NSURLAuthenticationMethodClientCertificate)
        let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: ClientCertificateSender())
        var replies = 0
        WebKitQuestions.authenticate(view, challenge, listener: browser) { disposition, credential in
            // This view has no window, so it cannot show a picker. Previously
            // this challenge fell through to performDefaultHandling.
            #expect(disposition == .cancelAuthenticationChallenge)
            #expect(credential == nil)
            replies += 1
        }
        #expect(replies == 1)
    }

    @Test func chromiumRejectsMissingOrMalformedCandidates() {
        let tab = Tab(shy: true), page = ChromiumPage(tab: tab)
        let values: [[String: JSONValue]] = [
            [:],
            ["host": .string("mtls.invalid"), "port": .number(443), "certificates": .array([])],
            ["host": .string("mtls.invalid"), "port": .number(443), "certificates": .array([.string("invalid")])],
            ["host": .string("mtls.invalid"), "port": .number(443), "certificates": .array([.string("YQ==")])],
            ["host": .string("mtls.invalid"), "port": .number(0), "certificates": .array([.string("YQ==")])]
        ]
        for value in values {
            var replies = 0
            page.receiveClientCertificate(value) { response in
                #expect(response["index"] == nil)
                replies += 1
            }
            #expect(replies == 1)
        }
    }
}

private final class ClientCertificateSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
