import WebKit

extension Store {
    /// Cookies, sign-ins, caches. WebKit keeps its default store per bundle,
    /// not per folder, so a test run got every site already signed in, and
    /// "sign out of everything" in a test run signed the real browser out.
    /// A test run gets a store of its own, under a fixed name so it persists
    /// between probes the way the real one does. Wiping the test store is
    /// then as safe as wiping its folder.
    static var websites: WKWebsiteDataStore {
        // Exact signed-app switch probes retain their bundle id. Their
        // explicit test world must not borrow that dev bundle's default jar.
        let switchProbe = testing && ProcessInfo.processInfo.environment["YAB_SWITCH_ISOLATE_WEBKIT"] == "1"
        let store = testing && (!ownContainer || switchProbe) ? WKWebsiteDataStore(forIdentifier: probeStore(1)) : .default()
        LastingSignIns.keep(store)
        return store
    }
}
