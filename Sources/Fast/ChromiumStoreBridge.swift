import Foundation

/// Reuse the existing store button and review, in a named Chromium world.
/// The renderer supplies no package ID; Browser reads the current store URL.
/// Chromium's store sees the install and redraws its header with Remove from
/// Chrome: that is its install button too, not a banner to hide with the header.
enum ChromiumStoreBridge {
    static let world = "yab-chromium-store"
    static let binding = "yabChromiumStore"
    static func accepts(_ url: URL?) -> Bool {
        url?.scheme == "https" && url?.host == "chromewebstore.google.com" && (url?.port == nil || url?.port == 443)
    }
    static let script = StoreRelay.script
        .replacingOccurrences(of: "window.webkit.messageHandlers.yabStore.postMessage({ placed: pageID() })",
                              with: "yabChromiumStore(JSON.stringify({ placed: pageID() }))")
        .replacingOccurrences(of: "window.webkit.messageHandlers.yabStore.postMessage({ add: true })",
                              with: "yabChromiumStore(JSON.stringify({ add: true }))")
        .replacingOccurrences(of: "document.querySelectorAll('button[disabled]')", with: "document.querySelectorAll('button')")
        // Promotions are hidden before discovery. Inspect the remaining live
        // Chrome control regardless of language or whether hydration has
        // already enabled it; the store's enabled localized button otherwise
        // keeps its own installer instead of reaching Yab's review.
        .replacingOccurrences(of: "/chrome/i.test(b.textContent || '')", with: "(/chrome/i.test(b.textContent || '') && b.getClientRects().length > 0)")
        .replacingOccurrences(of: "if (b.dataset.yab || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;",
                              with: "if (b.dataset.yab || /(add to|remove from) chrome/i.test(b.textContent || '') || !/chrome/i.test(b.getAttribute('aria-label') || '')) continue;")
        .replacingOccurrences(of: "if (!mine.disabled)", with: "if (e.isTrusted && !mine.disabled)")
}
