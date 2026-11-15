import Foundation
import Testing
@testable import Fast

// Who may speak for a page (RelayGuard.swift): which frames are the page's
// own, which origin a one-place relay serves, and how recent a click or a
// key has to be to stand behind a share of the screen.
@MainActor
struct RelayGuardTests {
    static let mail = URL(string: "https://mail.google.com/mail/u/0/")!

    @Test func theMainFrameIsAlwaysThePagesOwn() {
        #expect(RelayGuard.ownFrame(main: true, scheme: "https", host: "mail.google.com", top: Self.mail))
        // Whatever it says of itself: the main frame is the page on top.
        #expect(RelayGuard.ownFrame(main: true, scheme: "", host: "", top: nil))
    }

    @Test func aFrameOfTheSameSiteIsThePagesOwn() {
        for host in ["accounts.google.com", "mail.google.com", "GOOGLE.com", "docs.google.com"] {
            #expect(RelayGuard.ownFrame(main: false, scheme: "https", host: host, top: Self.mail), "\(host)")
        }
        let bbc = URL(string: "https://www.bbc.co.uk/news")!
        #expect(RelayGuard.ownFrame(main: false, scheme: "https", host: "static.bbc.co.uk", top: bbc))
        #expect(!RelayGuard.ownFrame(main: false, scheme: "https", host: "ads.evil.co.uk", top: bbc))
    }

    @Test func anotherSitesFrameIsNot() {
        for host in ["doubleclick.net", "googlesyndication.com", "google.com.evil.io", "evilgoogle.com", "meet.google.com.attacker.dev"] {
            #expect(!RelayGuard.ownFrame(main: false, scheme: "https", host: host, top: Self.mail), "\(host)")
        }
    }

    @Test func anOpaqueFrameIsNoOnes() {
        // A sandbox without allow-same-origin, a data: frame: no host at all.
        #expect(!RelayGuard.ownFrame(main: false, scheme: "", host: "", top: Self.mail))
        #expect(!RelayGuard.ownFrame(main: false, scheme: "data", host: "", top: Self.mail))
        // Nor is anything on a page with no address yet.
        #expect(!RelayGuard.ownFrame(main: false, scheme: "https", host: "mail.google.com", top: nil))
        #expect(!RelayGuard.ownFrame(main: false, scheme: "https", host: "mail.google.com", top: URL(string: "about:blank")))
    }

    @Test func theSchemeHasToMatch() {
        #expect(!RelayGuard.ownFrame(main: false, scheme: "http", host: "mail.google.com", top: Self.mail))
        #expect(!RelayGuard.ownFrame(main: false, scheme: "yab", host: "mail.google.com", top: Self.mail))
        let file = URL(fileURLWithPath: "/tmp/page.html")
        #expect(!RelayGuard.ownFrame(main: false, scheme: "file", host: "", top: file))
    }

    @Test func addressesAreTheirOwnSite() {
        let local = URL(string: "http://127.0.0.1:8751/shop")!
        #expect(RelayGuard.ownFrame(main: false, scheme: "http", host: "127.0.0.1", top: local))
        #expect(!RelayGuard.ownFrame(main: false, scheme: "http", host: "127.0.0.2", top: local))
        let six = URL(string: "http://[::1]:4000/")!
        #expect(RelayGuard.ownFrame(main: false, scheme: "http", host: "::1", top: six))
        #expect(RelayGuard.ownFrame(main: false, scheme: "http", host: "[::1]", top: six))
        // Ports aside, as a site is.
        let dev = URL(string: "http://localhost:3000/")!
        #expect(RelayGuard.ownFrame(main: false, scheme: "http", host: "localhost", top: dev))
    }

    @Test func aOnePlaceRelayHearsThatPlaceAlone() {
        #expect(RelayGuard.exactly(scheme: "https", host: "chromewebstore.google.com", "chromewebstore.google.com"))
        #expect(RelayGuard.exactly(scheme: "HTTPS", host: "Meet.Google.com", "meet.google.com"))
        #expect(!RelayGuard.exactly(scheme: "http", host: "meet.google.com", "meet.google.com"))
        #expect(!RelayGuard.exactly(scheme: "https", host: "evil.meet.google.com", "meet.google.com"))
        #expect(!RelayGuard.exactly(scheme: "https", host: "meet.google.com.evil.io", "meet.google.com"))
        #expect(!RelayGuard.exactly(scheme: "https", host: "google.com", "meet.google.com"))
    }

    @Test func developerModeHearsThisMacsOwnServers() {
        for (scheme, host) in [("http", "localhost"), ("http", "app.localhost"), ("https", "shop.test"), ("http", "127.0.0.1"),
                               ("http", "::1"), ("http", "[::1]"), ("HTTP", "LOCALHOST")] {
            #expect(RelayGuard.local(scheme: scheme, host: host), "\(scheme)://\(host)")
        }
        for (scheme, host) in [("https", "github.com"), ("http", "192.168.1.4"), ("http", "printer.local"), ("file", ""),
                               ("https", ""), ("yab", "localhost"), ("https", "localhost.evil.io"), ("https", "test.example.com")] {
            #expect(!RelayGuard.local(scheme: scheme, host: host), "\(scheme)://\(host)")
        }
    }

    @Test func aClickStandsBehindTheNextQuestionForFiveSeconds() {
        let page = NSObject()
        RelayGuard.felt(page, at: 100)
        #expect(RelayGuard.take(page, now: 104.9) == .page)
        // Used up by asking: one click, one question.
        #expect(RelayGuard.take(page, now: 105) == nil)

        RelayGuard.felt(page, at: 100)
        #expect(RelayGuard.take(page, now: 105) == .page)
        RelayGuard.felt(page, at: 100)
        #expect(RelayGuard.take(page, now: 105.1) == nil)
    }

    @Test func noClickNoQuestion() {
        #expect(RelayGuard.take(NSObject(), now: 100) == nil)
        #expect(RelayGuard.take(nil, now: 100) == nil)
        // A click from the future, a clock gone wrong, counts for nothing.
        let page = NSObject()
        RelayGuard.felt(page, at: 200)
        #expect(RelayGuard.take(page, now: 100) == nil)
    }

    @Test func aClickInOnePageIsntAnothers() {
        let one = NSObject(), other = NSObject()
        RelayGuard.felt(one, at: 100)
        #expect(RelayGuard.take(other, now: 101) == nil)
        #expect(RelayGuard.take(one, now: 101) == .page)
    }

    @Test func yabsOwnShareIsSaidApart() {
        let page = NSObject()
        RelayGuard.vouch(page, at: 100)
        #expect(RelayGuard.take(page, now: 101) == .yab)
        // The last hand is the one that counts.
        RelayGuard.vouch(page, at: 100)
        RelayGuard.felt(page, at: 101)
        #expect(RelayGuard.take(page, now: 102) == .page)
    }

    @Test func recentIsWithinFiveSecondsOnward() {
        #expect(RelayGuard.recent(10, now: 10))
        #expect(RelayGuard.recent(10, now: 15))
        #expect(!RelayGuard.recent(10, now: 15.01))
        #expect(!RelayGuard.recent(10, now: 9.99))
    }
}
