import Foundation
import Testing
@testable import Fast

struct DNSRetryTests {
    let url = URL(string: "https://recover.test/path?q=one")!

    @Test func recoveryNeedsANetworkRestorationAndAVisiblePage() {
        var retry = DNSRetry()
        retry.begin(URLRequest(url: url))
        retry.wait(code: NSURLErrorNotConnectedToInternet, failed: url, domain: NSURLErrorDomain)
        #expect(retry.pending)
        #expect(retry.take(visible: true) == nil)
        retry.networkRestored()
        #expect(retry.take(visible: false) == nil)
        #expect(retry.pending && retry.ready)
        #expect(retry.take(visible: true)?.url == url)
        #expect(retry.take(visible: true) == nil)
    }

    @Test func navigationStopAndCommitCancelRecovery() {
        var retry = DNSRetry()
        retry.begin(URLRequest(url: url))
        retry.wait(code: NSURLErrorNetworkConnectionLost, failed: url, domain: NSURLErrorDomain)
        retry.networkRestored()
        retry.begin(nil)
        #expect(retry.take(visible: true) == nil)
        retry.begin(URLRequest(url: URL(string: "https://elsewhere.test/")!))
        retry.networkRestored()
        #expect(retry.take(visible: true) == nil)
        retry.wait(code: NSURLErrorNotConnectedToInternet, failed: url, domain: NSURLErrorDomain)
        #expect(!retry.pending)
    }

    @Test func restorationBeforeTheErrorIsRememberedButALaterOutageDisarmsIt() {
        var retry = DNSRetry()
        retry.begin(URLRequest(url: url))
        retry.networkRestored()
        retry.wait(code: NSURLErrorNetworkConnectionLost, failed: url, domain: NSURLErrorDomain)
        let early = retry.take(visible: true)
        #expect(early?.url == url)

        retry.begin(URLRequest(url: url))
        retry.wait(code: NSURLErrorNotConnectedToInternet, failed: url, domain: NSURLErrorDomain)
        retry.networkRestored()
        retry.networkUnavailable()
        #expect(retry.take(visible: true) == nil)
        retry.networkRestored()
        let restored = retry.take(visible: true)
        #expect(restored?.url == url)
    }

    @Test func neverReplaysFormsBodiesInternalPagesOrOAuth() {
        var requests = ["POST", "PUT", "DELETE", "HEAD"].map { method in
            var request = URLRequest(url: url); request.httpMethod = method; return request
        }
        var body = URLRequest(url: url); body.httpBody = Data("form".utf8); requests.append(body)
        var stream = URLRequest(url: url); stream.httpBodyStream = InputStream(data: Data()); requests.append(stream)
        requests.append(URLRequest(url: URL(string: "file:///tmp/page")!))
        requests.append(URLRequest(url: URL(string: "https://fkmaohpngenfoccdgceedjkfhkdcohmg.chromiumapp.org/?code=fixture")!))
        for request in requests {
            var retry = DNSRetry(); retry.begin(request)
            retry.wait(code: NSURLErrorNotConnectedToInternet, failed: request.url, domain: NSURLErrorDomain)
            retry.networkRestored()
            #expect(retry.take(visible: true) == nil)
        }
    }

    @Test func chromiumCertificatesCancellationAndForeignDomainsNeverEnterRecovery() {
        for (domain, codes) in [("net", [-105, -106, -101]),
            (NSURLErrorDomain, [NSURLErrorCancelled, NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed]),
            ("WebKitErrorDomain", [NSURLErrorNotConnectedToInternet, 102, 204])] {
            for code in codes {
                var retry = DNSRetry(); retry.begin(URLRequest(url: url))
                retry.wait(code: code, failed: url, domain: domain)
                retry.networkRestored()
                #expect(!retry.pending && retry.take(visible: true) == nil)
            }
        }
    }
}
