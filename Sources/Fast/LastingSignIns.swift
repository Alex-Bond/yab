import Foundation
import WebKit

// A sign-in lasts as long as the site says it does. WebKit's tracking prevention (ITP), on by default in every app made
// with it, cut sign-ins short three ways: a cookie a page's own script
// writes lived at most 7 days; so did one a site sets from a server of its
// that answers under another site's name (accounts.youtube.com is
// google.com's) or from another network; and what a site keeps in its
// storage went after 7 days of use without a visit. YouTube signed out
// every week: its sign-in cookies come from accounts.youtube.com, in a
// frame, and expired, while LOGIN_INFO stayed a year, so the page half
// knew you and Sign In let you straight back in. Reddit's session, and
// others', went the same way (feedback #54).
//
// Tracking prevention is one switch in WebKit, and third-party cookie
// blocking is part of it: off, nothing blocks them. So cookies come back
// under Safari's old rule, "Allow from websites I visit": a frame or a
// request from another site can set one only for a site you have opened
// yourself. The ad networks you never open set nothing; Shield blocks the
// rest.
enum LastingSignIns {
    @MainActor private static let kept = NSMapTable<WKWebsiteDataStore, SignInReadiness>.weakToStrongObjects()
    private static let tracking = NSSelectorFromString("_setResourceLoadStatisticsEnabled:")
    private static let policy = NSSelectorFromString("_setCookieAcceptPolicy:completionHandler:")

    /// Once for each store that keeps what it has: the first space's and
    /// those of spaces with sign-ins of their own. A private window's
    /// forgets everything anyway and keeps WebKit's rules.
    static func keep(_ store: WKWebsiteDataStore) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { policyReady(store) {} }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { policyReady(store) {} } }
        }
    }

    /// A navigation may arrive before launch has restored the session jar.
    /// Private stores keep WebKit's rules and never receive kept cookies.
    @MainActor static func whenReady(_ store: WKWebsiteDataStore, done: @escaping @MainActor () -> Void) {
        guard store.isPersistent else { done(); return }
        policyReady(store) { KeptCookies.restore(done) }
    }

    @MainActor private static func policyReady(_ store: WKWebsiteDataStore, done: @escaping @MainActor () -> Void) {
        guard store.isPersistent, !LinkGap.cut("keep") else { done(); return }
        let gate: SignInReadiness
        if let known = kept.object(forKey: store) { gate = known }
        else {
            gate = SignInReadiness()
            kept.setObject(gate, forKey: store)
        }
        gate.whenReady(prepare: { ready in
            KeptCookies.watch(store)
            if store.responds(to: tracking) {
                typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(store.method(for: tracking), to: Set.self)(store, tracking, false)
            }
            let cookies = store.httpCookieStore
            guard cookies.responds(to: policy) else { ready(); return }
            // WebKit calls the handler without checking it: nil crashes on
            // the reply from the network process. It keeps it until then,
            // so it escapes: unmarked, Swift traps when the call returns.
            typealias Set = @convention(c) (AnyObject, Selector, UInt, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(cookies.method(for: policy), to: Set.self)(
                cookies, policy, HTTPCookie.AcceptPolicy.onlyFromMainDocumentDomain.rawValue, {
                    DispatchQueue.main.async { MainActor.assumeIsolated { ready() } }
                })
        }, done: done)
    }
}
