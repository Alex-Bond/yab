import AppKit
import SwiftUI

/// AppKit owns these windows' frames. SwiftUI may measure their contents,
/// but must not resize a window again from its windowDidLayout observer.
@MainActor
enum WindowHosting {
    private static var attaching: Set<ObjectIdentifier> = []

    /// Ordering a child panel out detaches it from its parent. A cached
    /// owner is still useful for observers, but cannot prove attachment
    /// when the same panel opens again.
    static func attach(_ panel: NSWindow, to window: NSWindow) {
        guard panel.parent !== window else { return }
        panel.parent?.removeChildWindow(panel)
        window.addChildWindow(panel, ordered: .above)
    }

    static func host<Content: View>(_ root: Content) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        return host
    }

    static func content<Content: View>(_ root: Content) -> NSView {
        measured(host(root))
    }

    /// Safe while SwiftUI is still attaching its content view. Reparenting
    /// waits until WindowSetup's next turn, after that installation returns.
    static func disableSizing(of window: NSWindow) {
        (window.contentView as? WindowFrameHosting)?.leaveWindowFrameToAppKit()
        (window.contentViewController as? WindowFrameHosting)?.leaveWindowFrameToAppKit()
    }

    /// The first browser window is made by a SwiftUI scene, not our host
    /// factory. Cover its type-erased root before fullscreen restoration.
    static func ownFrame(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard attaching.insert(id).inserted else { return }
        defer { attaching.remove(id) }
        let least = window.contentMinSize, most = window.contentMaxSize
        (window.contentViewController as? WindowFrameHosting)?.leaveWindowFrameToAppKit()
        guard let root = window.contentView, let host = root as? WindowFrameHosting else { return }
        host.leaveWindowFrameToAppKit()
        // This is the SwiftUI scene's host, not the one made by
        // WindowFloorLayout.host. Once nested in Frame it must also ignore
        // the title bar's changing safe area, or a reveal resizes the page.
        host.ignoreTitlebarSafeArea()
        // Even an empty sizingOptions host at the root resets the window's
        // contentMinSize during layout. A plain root removes that ownership
        // altogether, including updateAnimatedWindowSize's window path.
        window.contentView = measured(root)
        window.contentMinSize = least
        window.contentMaxSize = most
    }

    /// Some panels measure intrinsicContentSize and listen for its changes.
    /// Keep that measurement alive, but put a plain AppKit view at the root,
    /// as Small Window does, so the host cannot size the window itself.
    static func measured(_ host: NSView) -> NSView {
        let content = Frame(host)
        host.autoresizingMask = [.width, .height]
        content.addSubview(host)
        return content
    }

    /// Keep content-view coordinate conversions the same as before hosting
    /// moved one level down. The container itself has no intrinsic size.
    private final class Frame: NSView {
        private let contentIsFlipped: Bool
        init(_ host: NSView) {
            contentIsFlipped = host.isFlipped
            super.init(frame: host.frame)
        }
        required init?(coder: NSCoder) { nil }
        override var isFlipped: Bool { contentIsFlipped }
        /// Every cursor update nothing under the pointer answered passes
        /// here on its way to the window's arrow. Over a Chromium page that
        /// arrow is wrong: the page keeps its own cursor
        /// (ChromiumPage.answerCursorUpdate, R2498).
        override func cursorUpdate(with event: NSEvent) {
            CursorUpdateGuard.run(self) {
                if !ChromiumPage.answerCursorUpdate(in: window) { super.cursorUpdate(with: event) }
            }
        }
    }
}

@MainActor
private protocol WindowFrameHosting {
    func leaveWindowFrameToAppKit()
    func ignoreTitlebarSafeArea()
}

extension NSHostingView: WindowFrameHosting {
    fileprivate func ignoreTitlebarSafeArea() { safeAreaRegions = [] }
    fileprivate func leaveWindowFrameToAppKit() {
        if !sizingOptions.isEmpty { sizingOptions = [] }
    }
}

extension NSHostingController: WindowFrameHosting {
    fileprivate func ignoreTitlebarSafeArea() {
        (view as? WindowFrameHosting)?.ignoreTitlebarSafeArea()
    }
    fileprivate func leaveWindowFrameToAppKit() {
        if !sizingOptions.isEmpty { sizingOptions = [] }
    }
}
