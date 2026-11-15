import SwiftUI
import WebKit

/// Settings › Privacy › Clear History and Website Data, for the whole app:
/// this iPhone's history (what Recent and Frequent come from, and each
/// tab's Back and Forward), and its cookies, caches and other website data
/// in every store kept on disk: Shared and each space's own sign-ins, and
/// the pictures of its pages kept for All Tabs' cards (Tabs/TabPictures). The
/// tabs stay, and so does everything sync keeps with the Mac. Private's
/// store is memory only and goes with its tabs, so it isn't touched here.
@MainActor
enum BrowsingDataClear {
    /// Every website store this iPhone keeps on disk.
    static func persistentStores() async -> [WKWebsiteDataStore] {
        let ids = await WKWebsiteDataStore.allDataStoreIdentifiers
        return [WKWebsiteDataStore.default()] + ids.map { WKWebsiteDataStore(forIdentifier: $0) }
    }

    /// Everything websites keep in `stores`, cookies too. A store in memory
    /// (Private's) is left as it is.
    static func removeWebsiteData(from stores: [WKWebsiteDataStore]) async {
        for store in stores where store.isPersistent {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}

extension AppModel {
    /// The confirmed Clear History and Website Data. `stores` is for tests;
    /// the app clears every store on disk. The data goes first, then the
    /// pages lose their Back and Forward and the one in front comes back on
    /// its page with the cookies already gone.
    func clearHistoryAndWebsiteData(stores: [WKWebsiteDataStore]? = nil) async {
        profile?.clearHistory()
        let targets: [WKWebsiteDataStore]
        if let stores { targets = stores } else { targets = await BrowsingDataClear.persistentStores() }
        await BrowsingDataClear.removeWebsiteData(from: targets)
        if pages.clearHistory() { pagesReleased() }
        // What the pages looked like goes too: All Tabs' kept pictures.
        TabStack.of(self).forgetPictures()
        Haptics.play(.success, reason: Haptics.Reason.historyCleared)
        // Nothing on screen changes: the toast says it's done.
        say("History and Data Cleared", glyph: .broom)
    }
}

/// The question before it, from its own row: iOS's sheet with the
/// destructive choice (and a tap away from it to cancel).
struct ClearDataConfirmation: ViewModifier {
    @Environment(AppModel.self) private var app
    let asks: Bool

    func body(content: Content) -> some View {
        if asks {
            content.confirmationDialog("Clear History and Website Data?", isPresented: Binding(
                get: { SettingsUI.shared.confirmClearData },
                set: { SettingsUI.shared.confirmClearData = $0 }), titleVisibility: .visible) {
                Button("Clear History and Data", role: .destructive) {
                    Task { @MainActor in await app.clearHistoryAndWebsiteData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Websites sign you out. Your tabs and what syncs with your Mac stay.")
            }
        } else {
            content
        }
    }
}

extension Haptics.Reason {
    static let historyCleared = "history cleared"  // success: Clear History and Website Data
}
