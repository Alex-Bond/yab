import AppKit
import WebKit

@MainActor
enum PagePictures {
    /// Raw WebKit auxiliary views still participate in handoff tests and
    /// non-tab surfaces. Browser tabs always use their owned page handle.
    static func snapshot(_ view: NSView, shot: PageShot, done: @escaping @MainActor (NSImage?, Error?) -> Void) {
        if let page = view as? any PageHandle {
            page.snapshot(shot, done: done)
        } else if let web = view as? WKWebView {
            let config = WKSnapshotConfiguration()
            if let rect = shot.rect { config.rect = rect }
            if let width = shot.width { config.snapshotWidth = NSNumber(value: Double(width)) }
            config.afterScreenUpdates = shot.afterUpdates
            web.takeSnapshot(with: config) { image, error in
                MainActor.assumeIsolated { done(image, error) }
            }
        } else { done(nil, PageShotFailed()) }
    }
}

extension StageView {
    /// A drawing barrier for a live page arriving from Peek or another
    /// window. The remote engine serializes geometry before its snapshot;
    /// WebKit retains its existing presentation callback.
    static func afterPageDrawing(_ view: NSView, requirePaint: Bool = false, _ done: @escaping () -> Void) {
        if let web = view as? WKWebView {
            afterNextDrawing(web, requirePaint: requirePaint, done)
        } else if let page = view as? any PageHandle {
            page.snapshot(PageShot(width: 1, afterUpdates: true)) { image, error in
                if image != nil, error == nil { done() }
            }
        }
    }
}
