import Foundation

/// Tests only: pieces of a page's configuration taken out, one by one, to
/// find what puts ~20 ms between a link's response and its document
/// (docs/evidence/clean-gap-2026-10-13.md, round 11). YAB_LINKGAP names
/// them, joined by "+": config (a bare configuration: pool and store),
/// ext, prefs, paint, diary, localnet, ua, relays, shield, scripts,
/// docstart, docend, policy, bftrace, window (the tab and the window not
/// told of a navigation: no KVO writes, no start, commit or finish),
/// started (Tab.navigationStarted not called), kvo (the page's KVO writes
/// dropped; kvo.url, kvo.loading, kvo.title, kvo.back, kvo.forward,
/// kvo.tone one of them), url.extra (the url KVO's work past the address),
/// aw.wallet and aw.rest (the browser's watch of a tab's address: the
/// wallet's and payments' resets, and the rest), drawnflag (Tab.drawn not cleared at a start),
/// commitwork and finishwork (Browser's didCommit and didFinish past
/// their trace), keep (LastingSignIns), notices
/// (SiteNotices: the pool's notification provider and the store's delegate),
/// swipe (a trackpad gesture's begin not told to the page's swipe script).
/// For evals/scroll-ram: hover (WebKit's word on the link under the pointer
/// dropped, no link pill) and pillglass (the link pill on a plain ground).
enum LinkGap {
    nonisolated static let cuts: Set<String> = Set(
        (ProcessInfo.processInfo.environment["YAB_LINKGAP"] ?? "")
            .split(whereSeparator: { "+;".contains($0) }).map(String.init))

    nonisolated static func cut(_ piece: String) -> Bool { _ = said; return cuts.contains(piece) }

    /// Said once on standard error, so a run's log shows the cuts it had.
    private nonisolated static let said: Void = {
        guard !cuts.isEmpty else { return }
        FileHandle.standardError.write("LINKGAP \(cuts.sorted().joined(separator: "+"))\n".data(using: .utf8)!)
    }()
}
