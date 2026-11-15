import Foundation
import WebKit

// Another browser's sign-ins, thousands of cookies, into WebKit's stores
// without holding the main thread (Browser.takeCookies, the bench's
// cookie-pour, evals/cookie-import).
//
// Crash #60's stall log (0.35.11, macOS 15.8) had the welcome's import from
// Arc hold the main thread 1.5 s turning every cookie into an HTTPCookie
// ("phase cookies"), then 3.4, 2.2 and 4.4 s pouring them in batches of 150
// setCookie calls a turn ("cookies.set"): what one message costs WebKit's
// UI process grows with the jar and the Mac, so a fixed count is no bound.
// Now:
//
// - the cookies are made off the main thread, next to the read;
// - on macOS 26 a store takes a few hundred in one message (setCookies),
//   the next sent once WebKit has answered;
// - before it, one message a cookie, as many as fit in a few milliseconds,
//   the rest after WebKit has answered those, on a later turn.
//
// YAB_NARROW_COOKIE_POUR=0 does it the old way, for the eval's before;
// YAB_NARROW_COOKIE_BULK=0 takes macOS 15's way on macOS 26 too.
@MainActor
enum CookiePour {
    /// Cookies in one setCookies message (macOS 26).
    static let chunk = 300
    /// The longest a turn of the main thread spends sending one cookie a
    /// message (before macOS 26). At least one goes each turn.
    static let slice: TimeInterval = 0.004

    /// Chromium's cookies made into WebKit's, off the main thread unless the
    /// old way was asked for, then `got` on the main thread. Called from the
    /// queue that read them.
    nonisolated static func convert(_ found: [String: [Chromium.Cookie]],
                                    then got: @escaping @MainActor ([String: [HTTPCookie]]) -> Void) {
        guard Narrow.cookiePour else {
            DispatchQueue.main.async { MainActor.assumeIsolated { got(found.mapValues { $0.compactMap(\.http) }) } }
            return
        }
        let made = MainBudget.chunk("cookies.http") { found.mapValues { $0.compactMap(\.http) } }
        DispatchQueue.main.async { MainActor.assumeIsolated { got(made) } }
    }

    /// Every cookie into its store, then `done` with how many went in.
    static func pour(_ work: [(WKWebsiteDataStore, HTTPCookie)], then done: @escaping @MainActor (Int) -> Void) {
        guard !work.isEmpty else { done(0); return }
        guard Narrow.cookiePour else { batches(work, then: done); return }
        // Each store's cookies together, the stores in the order they came.
        var order: [ObjectIdentifier] = []
        var stores: [ObjectIdentifier: WKWebsiteDataStore] = [:]
        var cookies: [ObjectIdentifier: [HTTPCookie]] = [:]
        for (store, cookie) in work {
            let key = ObjectIdentifier(store)
            if stores[key] == nil { order.append(key); stores[key] = store }
            cookies[key, default: []].append(cookie)
        }
        Task { @MainActor in
            for key in order {
                guard let store = stores[key]?.httpCookieStore, let all = cookies[key] else { continue }
                if #available(macOS 26.0, *), Narrow.cookieBulk {
                    var index = 0
                    while index < all.count {
                        let part = Array(all[index..<min(index + chunk, all.count)])
                        index += part.count
                        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
                            MainBudget.chunk("cookies.set") { store.setCookies(part) { sent.resume() } }
                        }
                    }
                } else {
                    var index = 0
                    while index < all.count {
                        let group = DispatchGroup()
                        MainBudget.chunk("cookies.set") {
                            let began = ProcessInfo.processInfo.systemUptime
                            repeat {
                                group.enter()
                                store.setCookie(all[index]) { group.leave() }
                                index += 1
                            } while index < all.count && ProcessInfo.processInfo.systemUptime - began < slice
                        }
                        await withCheckedContinuation { (sent: CheckedContinuation<Void, Never>) in
                            group.notify(queue: .main) { sent.resume() }
                        }
                    }
                }
            }
            done(work.count)
        }
    }

    /// The old way: 150 setCookie calls a turn, whatever they cost.
    private static func batches(_ work: [(WKWebsiteDataStore, HTTPCookie)], then done: @escaping @MainActor (Int) -> Void) {
        let batch = 150
        var index = 0
        func step() {
            let end = min(index + batch, work.count)
            let group = DispatchGroup()
            MainBudget.chunk("cookies.set") {
                for i in index..<end {
                    group.enter()
                    work[i].0.httpCookieStore.setCookie(work[i].1) { group.leave() }
                }
            }
            index = end
            group.notify(queue: .main) {
                MainActor.assumeIsolated {
                    if index < work.count { step() } else { done(work.count) }
                }
            }
        }
        step()
    }

    /// `count` made-up cookies, as a big profile's jar is: a few hundred
    /// sites, a dozen or more cookies each, some for sessions. For the
    /// bench's cookie-pour (evals/cookie-import).
    nonisolated static func madeUp(_ count: Int, tag: String) -> [Chromium.Cookie] {
        (0..<count).map { i in
            let site = i % 400
            return Chromium.Cookie(host: ".site\(site)-\(tag).example", name: "c\(i / 400)", value: String(repeating: "v", count: 40) + "\(i)",
                                   path: "/", expires: i % 5 == 0 ? nil : Date().addingTimeInterval(86400 * 30),
                                   secure: i % 2 == 0, httpOnly: i % 3 == 0, sameSite: i % 4 - 1)
        }
    }
}
