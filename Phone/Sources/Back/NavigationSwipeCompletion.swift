import ObjectiveC
import UIKit

/// Keep WebKit's transition and pictures, but let distance finish a slow
/// swipe too. Only an ended gesture past half can override cancellation;
/// interruptions, reversals before half and UIKit's fast flicks stay native.
@MainActor
enum NavigationSwipeCompletion {
    static func record(_ message: String) {
        guard let path = ProcessInfo.processInfo.environment["YAB_SWIPES_JOURNAL"] else { return }
        let file = URL(fileURLWithPath: path)
        let data = Data((message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else { try? data.write(to: file) }
    }
    private final class Gestures {
        struct Entry {
            let pan: UIPanGestureRecognizer
            let direction: CGFloat

            var completes: Bool {
                guard pan.state == .ended, let view = pan.view, view.bounds.width > 0 else { return false }
                return pan.translation(in: view).x * direction / view.bounds.width > Metrics.Back.commit
            }
        }
        var pans: [Entry] = []
    }
    private static var key: UInt8 = 0

    static func install(on transition: UIPercentDrivenInteractiveTransition, pan: UIPanGestureRecognizer, direction: CGFloat = 1) {
        if let gestures = objc_getAssociatedObject(transition, &key) as? Gestures {
            if !gestures.pans.contains(where: { $0.pan === pan }) { gestures.pans.append(.init(pan: pan, direction: direction)) }
            return
        }
        guard let original = object_getClass(transition),
              let cancel = class_getInstanceMethod(original, #selector(UIPercentDrivenInteractiveTransition.cancel)) else { return }
        let name = "YabDistanceCompletion_" + String(cString: class_getName(original)).replacingOccurrences(of: ".", with: "_")
        let subclass: AnyClass
        if let existing = NSClassFromString(name) { subclass = existing }
        else {
            guard let made = objc_allocateClassPair(original, name, 0) else { return }
            let implementation = method_getImplementation(cancel)
            let block: @convention(block) (UIPercentDrivenInteractiveTransition) -> Void = { value in
                MainActor.assumeIsolated {
                    let pans = (objc_getAssociatedObject(value, &key) as? Gestures)?.pans ?? []
                    // UIKit's WebKit interactor reports percentComplete=0
                    // even while its page is across the screen. Use the
                    // recognizer's directed distance in its own viewport.
                    let completes = pans.contains(where: \.completes)
                    record("distance completion=\(completes) states=\(pans.map { $0.pan.state.rawValue })")
                    if completes {
                        value.finish()
                    } else {
                        typealias Cancel = @convention(c) (AnyObject, Selector) -> Void
                        unsafeBitCast(implementation, to: Cancel.self)(value, #selector(UIPercentDrivenInteractiveTransition.cancel))
                    }
                }
            }
            class_addMethod(made, #selector(UIPercentDrivenInteractiveTransition.cancel), imp_implementationWithBlock(block), method_getTypeEncoding(cancel))
            objc_registerClassPair(made)
            subclass = made
        }
        let gestures = Gestures()
        gestures.pans = [.init(pan: pan, direction: direction)]
        objc_setAssociatedObject(transition, &key, gestures, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        object_setClass(transition, subclass)
    }
}
