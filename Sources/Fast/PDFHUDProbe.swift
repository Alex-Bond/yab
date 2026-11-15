import AppKit
import ObjectiveC

/// The bench's PDF HUD adapter, preserving both WebKit implementations.
@MainActor
enum PDFHUDProbe {
    static func show(_ bar: NSView) -> Bool {
        let legacy = NSSelectorFromString("_setVisible:")
        if let method = class_getInstanceMethod(type(of: bar), legacy) {
            typealias Set = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(method_getImplementation(method), to: Set.self)(bar, legacy, true)
            return true
        }
        // WebKit's macOS 27 rewrite uses show and real NSButtons.
        let native = NSSelectorFromString("show")
        guard bar.responds(to: native) else { return false }
        bar.perform(native)
        return true
    }

    /// Window coordinates, in the same left-to-right order on both versions.
    static func controls(in bar: NSView) -> (frames: [NSRect], opacity: Double) {
        func nativeButtons(in view: NSView) -> [NSButton] {
            view.subviews.flatMap { sub in
                if let button = sub as? NSButton { return [button] }
                return nativeButtons(in: sub)
            }
        }
        let native = nativeButtons(in: bar)
        if let button = native.first {
            let frames = native.map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
            var opacity: CGFloat = 1
            var view: NSView? = button
            while let current = view {
                opacity *= current.isHidden ? 0 : current.alphaValue
                if current === bar { break }
                view = current.superview
            }
            return (frames, Double(opacity))
        }
        guard let root = bar.layer, let panel = root.sublayers?.first else { return ([], 0) }
        // The legacy panel's separator is narrower than a button.
        let frames = (panel.sublayers ?? []).filter { $0.frame.width >= 20 }.map { button in
            bar.convert(button.convert(button.bounds, to: root), to: nil)
        }
        return (frames, Double(panel.presentation()?.opacity ?? panel.opacity))
    }
}
