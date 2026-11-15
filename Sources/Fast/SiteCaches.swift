import Foundation
import WebKit

// What sites cache for themselves, let go of once you stop going there
// (#685, row 1127: Yab's size on disk kept growing with eight tabs).
//
// WebKit's tracking prevention used to do this: a site not used for 7 days
// lost what its scripts kept. LastingSignIns turns that off so sign-ins
// last, and with it nothing ever let go of a site's Cache Storage, its
// service worker's copies of the app, or its share of the HTTP cache. On
// one Mac a month in, 1 GB of Cache Storage was there, two thirds of it
// for sites not opened in over ten days (Slack alone 547 MB).
//
// So once a day the caches of sites you went to but not for two weeks go: Cache
// Storage, the disk and memory cache, offline app caches and the service
// worker that fills them, as ⇧⌘R throws them out for one site. Sign-ins,
// cookies, local storage and IndexedDB stay, so nobody is signed out and no
// site forgets your settings. A site open in a tab, or one allowed to send
// notifications (its service worker brings them), is never touched. The
// diary says when a site was last visited; with no diary to ask, nothing
// is removed.
@MainActor
enum SiteCaches {
    static let idle: TimeInterval = 14 * 86_400
    static let types: Set<String> = [
        WKWebsiteDataTypeDiskCache,
        WKWebsiteDataTypeMemoryCache,
        WKWebsiteDataTypeFetchCache,
        WKWebsiteDataTypeOfflineWebApplicationCache,
        WKWebsiteDataTypeServiceWorkerRegistrations,
    ]
    private static let lastKey = "siteCaches.last"
    private static var timer: Timer?

    /// After launch, then once a day while Yab stays open.
    static func start() {
        if Date().timeIntervalSince(Store.settings.object(forKey: lastKey) as? Date ?? .distantPast) > 86_400 {
            sweep()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { _ in
            MainActor.assumeIsolated { sweep() }
        }
    }

    /// The pass itself. `idle` shorter for tests; `done` gets the sites let go.
    static func sweep(idle: TimeInterval = SiteCaches.idle, done: @escaping ([String]) -> Void = { _ in }) {
        let open = Set(BrowserWindows.shared.browsers.flatMap(\.everyTab).compactMap { $0.address?.host()?.lowercased() })
        let notifying = Set(Store.settings.dictionaryRepresentation().compactMap { key, value -> String? in
            guard key.hasPrefix("notifications."), value as? Bool == true else { return nil }
            return URL(string: String(key.dropFirst("notifications.".count)))?.host()?.lowercased()
        })
        var stores: [WKWebsiteDataStore] = [Store.websites]
        for store in Spaces.madeStores.values where store.isPersistent && !stores.contains(where: { $0 === store }) {
            stores.append(store)
        }
        Diary.shared.lastVisits { visits in
            MainActor.assumeIsolated {
                guard let visits, !visits.isEmpty else { return done([]) }
                Store.settings.set(Date(), forKey: lastKey)
                let before = Date().addingTimeInterval(-idle)
                var gone: [String] = []
                var left = stores.count
                for store in stores {
                    store.fetchDataRecords(ofTypes: types) { records in
                        let names = stale(records.map(\.displayName), visits: visits, open: open,
                                          notifying: notifying, before: before)
                        let theirs = records.filter { names.contains($0.displayName.lowercased()) }
                        gone += theirs.map(\.displayName)
                        let finish = {
                            left -= 1
                            if left == 0 {
                                if !gone.isEmpty { print("site caches: let go of \(gone.count) sites") }
                                done(gone.sorted())
                            }
                        }
                        if theirs.isEmpty { finish() } else { store.removeData(ofTypes: types, for: theirs) { finish() } }
                    }
                }
            }
        }
    }

    /// Sites (WebKit's record names, "example.com", which cover their
    /// subdomains) whose caches may go: visited once, but not since
    /// `before`, none of them open in a tab, none allowed to send
    /// notifications. `visits` is the diary's last visit per host.
    nonisolated static func stale(_ names: [String], visits: [String: Date], open: Set<String>,
                                  notifying: Set<String>, before: Date) -> Set<String> {
        func covers(_ name: String, _ host: String) -> Bool {
            let host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            return host == name || host.hasSuffix("." + name)
        }
        var out: Set<String> = []
        for raw in names {
            let name = raw.lowercased()
            guard !name.isEmpty, !open.contains(where: { covers(name, $0) }),
                  !notifying.contains(where: { covers(name, $0) }) else { continue }
            // A site never visited is another's: a CDN, a frame. Its share of
            // the HTTP cache serves the sites you do use, and WebKit's own
            // limit already trims it.
            guard let last = visits.filter({ covers(name, $0.key) }).map(\.value).max() else { continue }
            if last < before { out.insert(name) }
        }
        return out
    }
}
