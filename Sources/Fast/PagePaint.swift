import WebKit

/// Returning a tab to its stage must not wait on the web content process.
/// StageView keeps the departing page visible until WebKit presents the
/// arriving page, then starts the turn asynchronously. Hidden pages still
/// leave the window and keep WebKit's normal background throttling.
enum PagePaint {
    @discardableResult
    static func configure(_ configuration: WKWebViewConfiguration) -> Bool {
        let selector = NSSelectorFromString("_setWaitsForPaintAfterViewDidMoveToWindow:")
        guard configuration.responds(to: selector) else { return false }
        typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(configuration.method(for: selector), to: Set.self)(configuration, selector, false)
        return true
    }
}
