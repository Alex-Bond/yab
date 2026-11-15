import AppKit
import Foundation
import Security
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
struct CertificatePolicyTests {
    // The same certificate is deliberately used for several destinations:
    // a user's exception must not become a host-wide or process-wide grant.
    static func certificate() throws -> SecTrust {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("certificate-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", folder.appendingPathComponent("key.pem").path,
                             "-outform", "DER", "-out", folder.appendingPathComponent("cert.der").path, "-subj", "/CN=localhost", "-days", "1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let data = try Data(contentsOf: folder.appendingPathComponent("cert.der"))
        let cert = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, "localhost" as CFString), &trust) == errSecSuccess)
        return try #require(trust)
    }

    /// The browser's answer to a challenge, which comes once trustd has
    /// answered off the main thread (Browser.trust).
    @MainActor private static func answer(_ browser: Browser, _ web: WKWebView, _ challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await withCheckedContinuation { done in
            browser.webView(web, didReceive: challenge) { done.resume(returning: ($0, $1)) }
        }
    }

    @MainActor @Test func loopbackDoesNotSilentlyTrustAnInvalidCertificate() async throws {
        let trust = try Self.certificate()
        #expect(!SecTrustEvaluateWithError(trust, nil))
        let browser = Browser(windowID: UUID())
        let web = WKWebView()
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let space = CertificateProtectionSpace(host: host, port: 8443, trust: trust)
            let challenge = URLAuthenticationChallenge(protectionSpace: space, proposedCredential: nil,
                previousFailureCount: 0, failureResponse: nil, error: nil, sender: CertificateChallengeSender())
            let (disposition, credential) = await Self.answer(browser, web, challenge)
            #expect(disposition == .cancelAuthenticationChallenge, "An unapproved local certificate was trusted for \(host)")
            #expect(credential == nil)
        }
    }

    /// Approvals in persistent stores are written to a file: one of the
    /// test's own, never the test world's.
    @MainActor static func ownFile() -> URL {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("certificate-exceptions-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("certificate-exceptions.json")
        CertificateExceptions.file = file
        CertificateExceptions.reload()
        return file
    }

    @MainActor @Test func approvalIsBoundToTheProfileHostPortAndCertificate() throws {
        _ = Self.ownFile()
        let trust = try Self.certificate()
        let replacement = try Self.certificate()
        _ = SecTrustEvaluateWithError(trust, nil)
        _ = SecTrustEvaluateWithError(replacement, nil)
        let web = WKWebView(), other = Self.view(store: .nonPersistent())
        let approved = try #require(CertificateException(host: "localhost", port: 8443, trust: trust))
        CertificateExceptions.allow(approved, in: web)
        #expect(CertificateExceptions.contains(approved, in: web))
        #expect(CertificateExceptions.contains(approved, in: WKWebView()))
        #expect(!CertificateExceptions.contains(approved, in: other))
        for candidate in [
            CertificateException(host: "localhost", port: 9443, trust: trust),
            CertificateException(host: "other.example", port: 8443, trust: trust),
            CertificateException(host: "localhost", port: 8443, trust: replacement),
        ] {
            #expect(!CertificateExceptions.contains(try #require(candidate), in: web))
        }
        #expect(CertificateException(host: "localhost", port: 0, trust: trust) == nil)
    }

    @MainActor @Test func challengeCannotReuseAnApprovalAtAnotherEndpoint() async throws {
        let trust = try Self.certificate()
        _ = SecTrustEvaluateWithError(trust, nil)
        _ = Self.ownFile()
        let browser = Browser(windowID: UUID())
        let web = WKWebView()
        CertificateExceptions.allow(try #require(CertificateException(host: "localhost", port: 8443, trust: trust)), in: web)
        for (view, host, port, shouldTrust) in [
            (web, "localhost", 8443, true),
            (web, "localhost", 9443, false),
            (web, "other.example", 8443, false),
            (Self.view(store: .nonPersistent()), "localhost", 8443, false),
        ] {
            let challenge = URLAuthenticationChallenge(protectionSpace: CertificateProtectionSpace(host: host, port: port, trust: trust),
                proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil, sender: CertificateChallengeSender())
            let (disposition, credential) = await Self.answer(browser, view, challenge)
            #expect((disposition == .useCredential) == shouldTrust)
            #expect((credential != nil) == shouldTrust)
        }
    }

    /// #494: a profile's approval outlives the launch, for that chain only;
    /// a private window's is never written down.
    @MainActor @Test func approvalSurvivesARelaunchOnlyForTheSameChain() throws {
        let file = Self.ownFile()
        let trust = try Self.certificate()
        let renewed = try Self.certificate()
        _ = SecTrustEvaluateWithError(trust, nil)
        _ = SecTrustEvaluateWithError(renewed, nil)
        let approved = try #require(CertificateException(host: "server.company.local", port: 443, trust: trust))
        CertificateExceptions.allow(approved, in: WKWebView())
        let secret = try #require(CertificateException(host: "secret.company.local", port: 443, trust: trust))
        let incognito = Self.view(store: .nonPersistent())
        CertificateExceptions.allow(secret, in: incognito)

        CertificateExceptions.reload()
        #expect(CertificateExceptions.contains(approved, in: WKWebView()))
        let renewal = try #require(CertificateException(host: "server.company.local", port: 443, trust: renewed))
        #expect(!CertificateExceptions.contains(renewal, in: WKWebView()))
        #expect(!CertificateExceptions.contains(secret, in: WKWebView()))
        #expect(!CertificateExceptions.contains(approved, in: Self.view(store: .nonPersistent())))
        let written = try String(contentsOf: file, encoding: .utf8)
        #expect(written.contains("server.company.local"))
        #expect(!written.contains("secret.company.local"), "A private window's approval was written down")

        // Clearing the site's data drops it, here and at the next launch.
        CertificateExceptions.forget(site: "company.local", in: WKWebView().configuration.websiteDataStore)
        CertificateExceptions.reload()
        #expect(!CertificateExceptions.contains(approved, in: WKWebView()))
        CertificateExceptions.forget(site: "company.local", in: incognito.configuration.websiteDataStore)
        #expect(!CertificateExceptions.contains(secret, in: incognito))
    }

    @MainActor private static func view(store: WKWebsiteDataStore) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        return WKWebView(frame: .zero, configuration: config)
    }

    @MainActor @Test func liveKeepAliveApprovalDoesNotCrossProfilesPortsOrCertificates() async throws {
        let fixture = try TLSSiteFixture()
        defer { fixture.stop() }
        let store = WKWebsiteDataStore.nonPersistent()
        let browser = Browser(windowID: UUID())
        var views: [WKWebView] = []
        // Keep the first page and HTTP/1.1 connection alive throughout.
        defer { views.forEach { $0.stopLoading() } }
        func load(_ fixture: TLSSiteFixture, store: WKWebsiteDataStore, grant: Bool = false, expected: Bool) async throws {
            let web = Self.view(store: store)
            views.append(web)
            let observer = CertificateNavigationObserver(browser)
            web.navigationDelegate = observer
            if grant {
                CertificateExceptions.allow(try #require(CertificateException(host: "127.0.0.1", port: fixture.port, trust: fixture.trust)), in: web)
            }
            web.load(URLRequest(url: URL(string: "https://127.0.0.1:\(fixture.port)/\(UUID().uuidString)")!))
            for _ in 0..<150 {
                if observer.finished != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(observer.finished == expected, "Unexpected TLS decision: \(String(describing: observer.finished))")
            if !expected { #expect(observer.challenges > 0) }
        }
        try await load(fixture, store: store, grant: true, expected: true)
        // A shared TLS connection is already approved for this profile.
        try await load(fixture, store: store, expected: true)
        try await load(fixture, store: .nonPersistent(), expected: false)
        let otherPort = try TLSSiteFixture()
        defer { otherPort.stop() }
        try await load(otherPort, store: store, expected: false)
        fixture.stop()
        let replacement = try TLSSiteFixture(port: fixture.port)
        defer { replacement.stop() }
        try await load(replacement, store: store, expected: false)
    }

}

@MainActor private final class CertificateNavigationObserver: NSObject, WKNavigationDelegate {
    let browser: Browser
    var finished: Bool?
    var challenges = 0
    init(_ browser: Browser) { self.browser = browser }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        challenges += 1
        browser.webView(webView, didReceive: challenge, completionHandler: completionHandler)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finished = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finished = false }
}

private final class CertificateProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    let shown: SecTrust
    init(host: String, port: Int, trust: SecTrust) {
        shown = trust
        super.init(host: host, port: port, protocol: "https", realm: nil, authenticationMethod: NSURLAuthenticationMethodServerTrust)
    }
    required init?(coder: NSCoder) { fatalError("Not used by this fixture") }
    override var serverTrust: SecTrust? { shown }
}

private final class CertificateChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
