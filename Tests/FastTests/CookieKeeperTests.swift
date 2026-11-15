import Foundation
import Testing
@testable import Fast

/// The session-cookie keeper off the main thread (KeptCookies,
/// docs/main-thread-budget.md): sweeps kept in order, written only on a
/// change or once a day, removed when none are left, and the way out
/// waited for.
struct CookieKeeperTests {
    final class Keychain: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        private(set) var last: Data?
        func wrote(_ data: Data) { lock.lock(); log.append("write"); last = data; lock.unlock() }
        func removed() { lock.lock(); log.append("remove"); last = nil; lock.unlock() }
        var events: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private func keeper() -> (CookieKeeper, Keychain) {
        let chain = Keychain()
        return (CookieKeeper(write: { chain.wrote($0) }, remove: { chain.removed() }), chain)
    }

    private func cookie(_ name: String, _ value: String, session: Bool = true, domain: String = "example.test") -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if !session { properties[.expires] = Date().addingTimeInterval(3600) }
        return HTTPCookie(properties: properties)!
    }

    private func saved(_ chain: Keychain) -> CookieKeeper.Kept? {
        chain.last.flatMap { try? JSONDecoder().decode(CookieKeeper.Kept.self, from: $0) }
    }

    @Test func onlySessionCookiesAreKept() {
        let jars = ["first": [cookie("sid", "1"), cookie("pref", "x", session: false)]]
        let kept = CookieKeeper.session(jars)
        #expect(kept["first"]?.map(\.name) == ["sid"])
        #expect(CookieKeeper.session(["first": [cookie("pref", "x", session: false)]]).isEmpty)
    }

    @Test func writtenOnceUntilTheCookiesChange() {
        let (keeper, chain) = keeper()
        let now = Date()
        keeper.keepNow(["first": [cookie("sid", "1")]], at: now)
        // The same cookies, in another order and with another one that
        // lasts, change nothing.
        keeper.keepNow(["first": [cookie("pref", "x", session: false), cookie("sid", "1")]], at: now.addingTimeInterval(30))
        #expect(chain.events == ["write"])
        keeper.keepNow(["first": [cookie("sid", "2")]], at: now.addingTimeInterval(60))
        #expect(chain.events == ["write", "write"])
        #expect(saved(chain)?.stores["first"]?.first?.value == "2")
    }

    @Test func writtenAgainAfterADay() {
        let (keeper, chain) = keeper()
        let now = Date()
        keeper.keepNow(["first": [cookie("sid", "1")]], at: now)
        keeper.keepNow(["first": [cookie("sid", "1")]], at: now.addingTimeInterval(25 * 3600))
        #expect(chain.events == ["write", "write"])
    }

    @Test func removedWhenNoneAreLeftAndOnlyOnce() {
        let (keeper, chain) = keeper()
        keeper.keepNow(["first": [cookie("sid", "1")]], at: Date())
        keeper.keepNow(["first": []], at: Date())
        keeper.keepNow([:], at: Date())
        #expect(chain.events == ["write", "remove"])
    }

    @Test func aRunThatKnowsNothingRemovesAnOldItem() {
        let (keeper, chain) = keeper()
        keeper.keepNow([:], at: Date())
        #expect(chain.events == ["remove"])
    }

    @Test func laterSweepsLandInTheOrderTaken() {
        let (keeper, chain) = keeper()
        let now = Date()
        for n in 0..<50 { keeper.keepLater(["first": [cookie("sid", "\(n)")]], at: now.addingTimeInterval(Double(n))) }
        keeper.settle()
        #expect(chain.events.count == 50)
        #expect(saved(chain)?.stores["first"]?.first?.value == "49")
    }

    @Test func aLaterSweepReturnsAtOnce() {
        let (keeper, chain) = keeper()
        let jar = (0..<5000).map { cookie("c\($0)", "\($0)") }
        keeper.queue.suspend()
        keeper.keepLater(["first": jar], at: Date())
        // Nothing done yet: the caller was not held for it.
        #expect(chain.events.isEmpty)
        keeper.queue.resume()
        keeper.settle()
        #expect(saved(chain)?.stores["first"]?.count == 5000)
    }

    @Test func restoredItemIsKnownAndNotWrittenAgain() throws {
        let (keeper, chain) = keeper()
        let stores = ["first": [CookieKeeper.Cookie(cookie("sid", "1"))]]
        let data = try JSONEncoder().encode(CookieKeeper.Kept(saved: Date(), stores: stores))
        #expect(keeper.restore(data, lifetime: 7 * 86_400)?.stores["first"]?.first?.name == "sid")
        keeper.keepNow(["first": [cookie("sid", "1")]], at: Date())
        #expect(chain.events.isEmpty)
    }

    @Test func anOldItemIsRemovedAtRestore() throws {
        let (keeper, chain) = keeper()
        let data = try JSONEncoder().encode(CookieKeeper.Kept(saved: Date().addingTimeInterval(-8 * 86_400), stores: [:]))
        #expect(keeper.restore(data, lifetime: 7 * 86_400) == nil)
        #expect(chain.events == ["remove"])
    }

    @Test func aKeptCookieGoesBackAsItCame() {
        let kept = CookieKeeper.Cookie(name: "sid", value: "1", domain: ".example.test", path: "/", secure: true, httpOnly: true, sameSite: "lax")
        let back = kept.cookie
        #expect(back?.isSecure == true)
        #expect(back?.isHTTPOnly == true)
        #expect(back?.isSessionOnly == true)
    }
}
