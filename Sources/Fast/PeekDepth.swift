import AppKit
import QuartzCore

/// The whole native card recedes under Peek without changing its viewport. A single
/// layer transform is committed per transition; WebKit, SwiftUI and layout
/// do no work per animation frame. The carrier includes the paper, address
/// bar and native overlays as well as WebKit; Peek is its unscaled sibling.
@MainActor
final class PeekDepth {
    static let inset: CGFloat = 12
    static let key = "peek.depth"
    private weak var surface: NSView?
    private var base = CATransform3DIdentity
    private var geometry = CGRect.zero
    private var geometryTop = true
    /// Existing room outside the card: left, top, right, bottom. The
    /// recessed card has one final gap, including this original padding.
    var padding: [CGFloat] = [0, 0, 0, 0] {
        didSet {
            guard padding != oldValue else { return }
            set(recessed, animated: false)
        }
    }
    private(set) var recessed = false
    /// Told each time the card is set to a place, before it is drawn there.
    var moved: (@MainActor () -> Void)?

    /// How far below its frame's top the card's top edge stands, or will
    /// once a move under way has settled.
    var topInset: CGFloat {
        guard let layer = surface?.layer else { return 0 }
        return Self.drawnInsets(layer, topAtMaxY: topAtMaxY)[1]
    }

    func bind(surface next: NSView?) {
        guard next !== surface else { return }
        set(false, animated: false)
        surface = next
        base = next?.layer?.transform ?? CATransform3DIdentity
        geometry = next?.layer?.bounds ?? .zero
    }

    func set(_ on: Bool, animated: Bool, reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        recessed = on && !reducedMotion
        guard let layer = surface?.layer else { return }
        geometry = layer.bounds
        geometryTop = topAtMaxY
        let target = recessed ? CATransform3DConcat(Self.insetTransform(layer, inset: Self.inset, padding: padding, topAtMaxY: geometryTop), base) : base
        // AppKit's model has already reached the destination. Interruptions
        // start at the pixels currently shown, including a mid-close reopen.
        let shown = layer.presentation()?.transform ?? layer.transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (surface as? PeekCardView)?.recede(recessed, animated: animated && !reducedMotion)
        layer.removeAnimation(forKey: Self.key)
        layer.transform = target
        if animated, !reducedMotion, !CATransform3DEqualToTransform(shown, target) {
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1
            spring.stiffness = 420
            spring.damping = 38
            spring.fromValue = NSValue(caTransform3D: shown)
            spring.toValue = NSValue(caTransform3D: target)
            spring.duration = min(0.5, spring.settlingDuration)
            layer.add(spring, forKey: Self.key)
        }
        CATransaction.commit()
        moved?()
    }

    /// Real window resizes update the center once in the ordinary layout
    /// pass. Opening and closing Peek never ask for a layout themselves.
    func refresh() {
        guard let layer = surface?.layer, layer.bounds != geometry || topAtMaxY != geometryTop else { return }
        set(recessed, animated: false)
    }

    /// NSView layers need not be anchored at their center. Keep both the
    /// view's frame and the document's frame untouched, for any anchor.
    static func insetTransform(_ layer: CALayer, inset: CGFloat, padding: [CGFloat] = [0, 0, 0, 0], topAtMaxY: Bool = true) -> CATransform3D {
        let bounds = layer.bounds
        guard bounds.width > 0, bounds.height > 0 else { return CATransform3DIdentity }
        let gap = (padding.max() ?? 0) + min(inset, min(bounds.width, bounds.height) * 0.05)
        let edges = padding.map { max(0, gap - $0) }
        let x = 1 - (edges[0] + edges[2]) / bounds.width
        let y = 1 - (edges[1] + edges[3]) / bounds.height
        let dx = edges[0] - layer.anchorPoint.x * (edges[0] + edges[2])
        let dy = edges[topAtMaxY ? 3 : 1] - layer.anchorPoint.y * (edges[1] + edges[3])
        return CATransform3DConcat(CATransform3DMakeScale(x, y, 1),
                                 CATransform3DMakeTranslation(dx, dy, 0))
    }

    private var topAtMaxY: Bool {
        guard let surface else { return true }
        let here = surface.convertToLayer(NSPoint.zero).y
        let up = surface.convertToLayer(NSPoint(x: 0, y: surface.isFlipped ? -1 : 1)).y
        return up > here
    }

    static func drawnInsets(_ layer: CALayer, topAtMaxY: Bool = true) -> [CGFloat] {
        let t = layer.transform, b = layer.bounds, a = layer.anchorPoint
        let left = b.width * a.x * (1 - t.m11) + t.m41
        let right = b.width * (1 - a.x) * (1 - t.m11) - t.m41
        let low = b.height * a.y * (1 - t.m22) + t.m42
        let high = b.height * (1 - a.y) * (1 - t.m22) - t.m42
        return [left, topAtMaxY ? high : low, right, topAtMaxY ? low : high]
    }

    var state: [String: Any] {
        guard let layer = surface?.layer else { return ["bound": false] }
        return ["bound": true, "recessed": recessed, "scale": layer.transform.m11,
                "surface": String(describing: type(of: surface!)), "scaleY": layer.transform.m22,
                "insets": Self.drawnInsets(layer, topAtMaxY: topAtMaxY),
                "gaps": zip(Self.drawnInsets(layer, topAtMaxY: topAtMaxY), padding).map { $0.0 + $0.1 },
                "padding": padding,
                "gap": (padding.max() ?? 0) + min(Self.inset, min(layer.bounds.width, layer.bounds.height) * 0.05),
                "shownScale": (layer.presentation() ?? layer).transform.m11,
                "animations": layer.animationKeys() ?? [],
                "translation": [layer.transform.m41, layer.transform.m42],
                "centerShift": [layer.bounds.width * (0.5 - layer.anchorPoint.x) * (layer.transform.m11 - 1) + layer.transform.m41,
                                layer.bounds.height * (0.5 - layer.anchorPoint.y) * (layer.transform.m22 - 1) + layer.transform.m42],
                "bounds": [layer.bounds.width, layer.bounds.height]]
    }
}
