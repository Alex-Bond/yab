import Foundation
import Testing
@testable import Fast

/// A typed address that answers at its other name only, www. on or off
/// (register 1023: portaldasfinancas.gov.pt has no address in DNS).
struct WWWRetryTests {
    private func other(_ address: String) -> String? {
        WWWRetry.other(URL(string: address)!)?.absoluteString
    }

    @Test func theOtherNameIsWwwPutOnOrTakenOff() {
        #expect(other("https://portaldasfinancas.gov.pt") == "https://www.portaldasfinancas.gov.pt")
        #expect(other("https://portaldasfinancas.gov.pt/at/html/index.html?x=1") == "https://www.portaldasfinancas.gov.pt/at/html/index.html?x=1")
        #expect(other("https://www.example.com/") == "https://example.com/")
        #expect(other("http://example.com/") == "http://www.example.com/")
        #expect(other("https://EXAMPLE.com/") == "https://www.example.com/")
    }

    @Test func noOtherNameForPortsLocalNamesAddressesOrOtherSchemes() {
        #expect(other("https://example.com:8443/") == nil)
        #expect(other("http://192.168.1.20/") == nil)
        #expect(other("http://8.8.8.8/") == nil)
        #expect(other("http://[fe80::1]/") == nil)
        #expect(other("http://printer.local/") == nil)
        #expect(other("http://localhost/") == nil)
        #expect(other("http://nas/") == nil)
        #expect(other("https://www.com/") == nil)
        #expect(other("ftp://example.com/") == nil)
        #expect(other("file:///Users/me/a.html") == nil)
        #expect(other("yab://settings") == nil)
    }

    @Test func onlyFailuresOfTheNameAreRetried() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost,
                     NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                     NSURLErrorSecureConnectionFailed] {
            #expect(WWWRetry.retries(code))
        }
        for code in [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                     NSURLErrorCancelled, NSURLErrorBadServerResponse, 102] {
            #expect(!WWWRetry.retries(code))
        }
    }

    @Test func theKeyReadsAnEmptyPathAsWebKitSendsIt() {
        #expect(WWWRetry.key(URL(string: "https://Portaldasfinancas.gov.pt")!) == "https://portaldasfinancas.gov.pt/")
        #expect(WWWRetry.key(URL(string: "https://portaldasfinancas.gov.pt/")!) == "https://portaldasfinancas.gov.pt/")
        #expect(WWWRetry.key(URL(string: "https://a.com/b?c=1")!) == "https://a.com/b?c=1")
    }

    @MainActor @Test func aTypedAddressGetsOneLookAndALinkNone() {
        let now = Date()
        let typed = URL(string: "https://portaldasfinancas.gov.pt")!
        // WebKit names the failing address with its slash.
        let failing = URL(string: "https://portaldasfinancas.gov.pt/")!
        WWWRetry.typed(typed, at: now)
        // A timeout says nothing of the name, and does not use the look up.
        #expect(WWWRetry.claim(failing, code: NSURLErrorTimedOut, at: now) == nil)
        #expect(WWWRetry.claim(failing, code: NSURLErrorCannotFindHost, at: now)?.absoluteString
                == "https://www.portaldasfinancas.gov.pt/")
        // Asked once: a second failure is the page's own.
        #expect(WWWRetry.claim(failing, code: NSURLErrorCannotFindHost, at: now) == nil)
        // Never typed, a link in a page: never rewritten.
        #expect(WWWRetry.claim(URL(string: "https://linked-only.example/")!, code: NSURLErrorCannotFindHost, at: now) == nil)
    }

    @MainActor @Test func aFailureLongAfterReturnIsNotTheTypedAddresses() {
        let then = Date()
        let typed = URL(string: "https://late.example/")!
        WWWRetry.typed(typed, at: then)
        #expect(WWWRetry.claim(typed, code: NSURLErrorCannotFindHost, at: then.addingTimeInterval(WWWRetry.patience + 1)) == nil)
    }

    @Test func theWorkingNameIsKeptAndFollowedBackWhenItMoves() {
        let settings = UserDefaults(suiteName: "WWWRetryTests-\(UUID().uuidString)")!
        let bare = URL(string: "https://portaldasfinancas.gov.pt/")!
        let www = URL(string: "https://www.portaldasfinancas.gov.pt/")!
        #expect(WWWRetry.preferred(bare, in: settings) == bare)
        WWWRetry.keep(bare, answered: www, in: settings)
        #expect(WWWRetry.preferred(URL(string: "https://portaldasfinancas.gov.pt/at/x?y=1")!, in: settings).absoluteString
                == "https://www.portaldasfinancas.gov.pt/at/x?y=1")
        // The www name typed itself is left as it is.
        #expect(WWWRetry.preferred(www, in: settings) == www)
        // The site moved back: the other way round replaces it, no circle.
        WWWRetry.keep(www, answered: bare, in: settings)
        #expect(WWWRetry.preferred(bare, in: settings) == bare)
        #expect(WWWRetry.preferred(www, in: settings) == bare)
        // A port, a local name: never rewritten, whatever is kept.
        #expect(WWWRetry.preferred(URL(string: "https://portaldasfinancas.gov.pt:8443/")!, in: settings).port == 8443)
    }
}
