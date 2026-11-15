import Foundation
import UIKit
import WebKit

/// The part of a real webpage visible between the hardware edges and Yab's
/// floating chrome. WebKit handles fixed elements and CSS viewport units;
/// webpages keep ownership of their own safe-area CSS.
struct PageViewport: Equatable {
    struct Chrome: Equatable {
        var folded: Bool
        var hasNow: Bool
        var visible: Bool
        var verticalControls: Bool? = nil
        var leadingRail = false
    }

    let size: CGSize
    let hardware: UIEdgeInsets
    let chrome: Chrome

    var minimum: UIEdgeInsets { insets(folded: true) }
    var maximum: UIEdgeInsets { insets(folded: false) }
    var current: UIEdgeInsets { insets(folded: chrome.folded) }

    private func insets(folded: Bool) -> UIEdgeInsets {
        let layout = ChromeGeometry(size: size, folded: folded, hasNow: chrome.hasNow, verticalControls: chrome.verticalControls, leadingRail: chrome.leadingRail)
        let topOfChrome = chrome.hasNow ? min(layout.plate.minY, layout.now.minY) : layout.plate.minY
        let occupied = chrome.visible ? max(0, size.height - topOfChrome) : 0
        // Keep interactive content inside each hardware edge. WebKit owns
        // the background that extends beneath the system column.
        let sides = ChromeGeometry.Sides(left: max(0, hardware.left), right: max(0, hardware.right))
        return UIEdgeInsets(top: max(0, hardware.top), left: sides.left,
                            bottom: max(max(0, hardware.bottom), occupied), right: sides.right)
    }

    private func fitting(_ insets: UIEdgeInsets, to size: CGSize) -> UIEdgeInsets {
        func axis(_ start: CGFloat, _ end: CGFloat, length: CGFloat) -> (CGFloat, CGFloat) {
            let first = start.isFinite ? max(0, start) : 0
            let last = end.isFinite ? max(0, end) : 0
            let limit = max(0, length - 1)
            let total = first + last
            guard total > limit else { return (first, last) }
            let scale = limit / total
            return (first * scale, last * scale)
        }
        let vertical = axis(insets.top, insets.bottom, length: size.height)
        let horizontal = axis(insets.left, insets.right, length: size.width)
        return UIEdgeInsets(top: vertical.0, left: horizontal.0, bottom: vertical.1, right: horizontal.1)
    }

    // Each live page receives this layout. A global Boolean would also
    // silence a different page while WebKit delivers a nested callback.
    @MainActor private static var applying: [ObjectIdentifier: Int] = [:]

    @MainActor
    static func isApplying(to view: WKWebView) -> Bool {
        applying[ObjectIdentifier(view), default: 0] > 0
    }

    /// When each page last had its insets written (system uptime). A page's
    /// own scrollers re-lay themselves out after that, and their scroll
    /// events are not a person's swipe.
    @MainActor private static var wrote: [ObjectIdentifier: TimeInterval] = [:]
    static let settleTime: TimeInterval = 0.6

    @MainActor
    static func recentlyWrote(to view: WKWebView, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let time = wrote[ObjectIdentifier(view)] else { return false }
        return now - time < settleTime
    }

    @MainActor
    func apply(to view: WKWebView) {
        MainStalls.count("viewport")
        UpdateLoops.count(.viewport) {
            var inputs = UpdateLoops.Fingerprint(fields: [
                "view": Double(ObjectIdentifier(view).hashValue),
                "refreshing": view.scrollView.refreshControl?.isRefreshing == true ? 1 : 0,
            ])
            inputs.chrome(chrome)
            inputs.size("size", size)
            inputs.size("frame", view.frame.size)
            inputs.insets("hardware", hardware)
            inputs.insets("requested.minimum", self.minimum)
            inputs.insets("requested.maximum", self.maximum)
            inputs.insets("requested.current", self.current)
            inputs.insets("applied.minimum", view.minimumViewportInset)
            inputs.insets("applied.maximum", view.maximumViewportInset)
            inputs.insets("applied.current", view.obscuredContentInsets)
            inputs.insets("scroll.content", view.scrollView.contentInset)
            inputs.insets("scroll.indicators", view.scrollView.verticalScrollIndicatorInsets)
            return inputs
        }
        // UIKit can briefly lay out a small view during a transition. WebKit
        // throws an Objective-C exception if either inset pair empties its frame.
        let frame = view.frame.size
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
        let maximum = fitting(self.maximum, to: frame)
        let folded = fitting(self.minimum, to: frame)
        let minimum = UIEdgeInsets(top: min(folded.top, maximum.top), left: min(folded.left, maximum.left),
                                   bottom: min(folded.bottom, maximum.bottom), right: min(folded.right, maximum.right))
        let current = chrome.folded ? minimum : maximum
        let refreshTop = view.scrollView.refreshControl?.isRefreshing == true
            ? max(0, view.scrollView.contentInset.top - view.obscuredContentInsets.top) : 0
        var scrollInsets = current
        scrollInsets.top += refreshTop
        guard view.minimumViewportInset != minimum || view.maximumViewportInset != maximum
                || view.obscuredContentInsets != current || view.scrollView.contentInset != scrollInsets
                || view.scrollView.verticalScrollIndicatorInsets != current else { return }
        // These setters can synchronously move contentOffset even during a
        // drag or deceleration. That movement is layout, not a new swipe.
        let identity = ObjectIdentifier(view)
        Self.wrote[identity] = ProcessInfo.processInfo.systemUptime
        Self.applying[identity, default: 0] += 1
        defer {
            if Self.applying[identity] == 1 { Self.applying.removeValue(forKey: identity) }
            else { Self.applying[identity, default: 1] -= 1 }
        }
        if view.minimumViewportInset != minimum || view.maximumViewportInset != maximum {
            view.setMinimumViewportInset(minimum, maximumViewportInset: maximum)
        }
        if view.obscuredContentInsets != current { view.obscuredContentInsets = current }
        // .never prevents UIKit from adding the hardware edges a second time.
        // The scroll range and indicators need the same edges as the viewport.
        if view.scrollView.contentInset != scrollInsets { view.scrollView.contentInset = scrollInsets }
        if view.scrollView.verticalScrollIndicatorInsets != current {
            view.scrollView.verticalScrollIndicatorInsets = current
        }
    }
}

/// Geometry that can move the scroll position without a person's movement.
struct PageScrollGeometry: Equatable {
    let size: CGSize
    let contentSize: CGSize
    let contentInsets: UIEdgeInsets
    let viewportInsets: UIEdgeInsets

    @MainActor
    init(_ view: WKWebView) {
        size = view.scrollView.bounds.size
        contentSize = view.scrollView.contentSize
        contentInsets = view.scrollView.adjustedContentInset
        viewportInsets = view.obscuredContentInsets
    }
}
