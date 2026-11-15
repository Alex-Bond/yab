import ObjectiveC
import WebKit

/// `closeAllMediaPresentationsWithCompletionHandler:` in the WebKit of
/// macOS 15 and 26 (Safari 18 and 26) keeps its completion block in a
/// CallbackAggregator without copying or retaining it: WKWebView.mm is
/// built without ARC and does `CallbackAggregator::create(WTFMove(
/// completionHandler))`, a raw block pointer in a CompletionHandler. WebKit's
/// main branch wraps it in `makeBlockPtr`. The aggregator lives until every
/// presentation has closed, and a video out in Picture in Picture closes
/// only when its window says so (`pipDidClose:`, which Yab's own window
/// sends a turn later, FloatPiP.swift). Swift's block for a caller's closure
/// is freed as the call returns, so WebKit then called freed memory: PC 0,
/// 0x2, 0x3 or a heap address under `~CallbackAggregatorOnThread`, from
/// `pipDidClose:` (#660, #805-808, #847, #1027, #1028, #1039, #1288, #1343,
/// #1510, #1511, #1514, #1543, #1544; 0.46.2 to 0.46.18, macOS 15.7 to 26.2).
/// The block WebKit gets is kept here until WebKit has called it.
enum MediaPresentationClose {
    private typealias Send = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    private static let selector = NSSelectorFromString("closeAllMediaPresentationsWithCompletionHandler:")
    /// Blocks WebKit holds and hasn't called yet.
    @MainActor private static var kept: [UUID: AnyObject] = [:]
    @MainActor static var waiting: Int { kept.count }

    /// `cls` is whose implementation is called: WKWebView's own, under
    /// PageView's override (a test passes a stand-in).
    @MainActor static func send(_ web: AnyObject, then done: (@MainActor @Sendable () -> Void)?,
                                through cls: AnyClass = WKWebView.self) {
        let id = UUID()
        let block: @convention(block) () -> Void = {
            // Called once, by whichever thread lets the aggregator go; the
            // block is let go a turn later, not while it runs.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    kept[id] = nil
                    done?()
                }
            }
        }
        let object = block as AnyObject
        kept[id] = object
        let imp = class_getMethodImplementation(cls, selector)
        unsafeBitCast(imp, to: Send.self)(web, selector, object)
    }
}
