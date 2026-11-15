import AppKit
import SwiftUI

/// Option D. Only Core Animation advances the searching stroke; the row stays still.
struct InstantLinksMark: NSViewRepresentable {
    let searching: Bool
    let icon: NSImage?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var still

    func makeNSView(context: Context) -> InstantLinksMarkView { InstantLinksMarkView() }
    func updateNSView(_ view: InstantLinksMarkView, context: Context) {
        view.configure(searching: searching, icon: icon, color: NSColor(tint), still: still)
    }
}

final class InstantLinksMarkView: NSView {
    private let place = CAShapeLayer()
    private let stroke = CAShapeLayer()
    private let favicon = CALayer()
    private var searching = false
    private var still = false
    private var image: NSImage?
    private var hasImage = false
    private var pathLength: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for shape in [place, stroke] {
            shape.fillColor = nil
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        favicon.contentsGravity = .resizeAspect
        layer?.addSublayer(favicon)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }

    func configure(searching: Bool, icon: NSImage?, color: NSColor, still: Bool) {
        self.searching = searching
        self.still = still
        let found = !searching && icon != nil
        let changed = image !== icon
        let arrive = found && !hasImage
        image = icon
        hasImage = found
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        place.strokeColor = color.withAlphaComponent(0.28).cgColor
        stroke.strokeColor = color.cgColor
        place.opacity = found ? 0 : 1
        stroke.opacity = searching && !found ? 1 : 0
        favicon.opacity = found ? 1 : 0
        if changed { favicon.contents = icon?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
        CATransaction.commit()
        if arrive && !still {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0; fade.toValue = 1; fade.duration = 0.2
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.6; grow.toValue = 1; grow.duration = 0.2
            grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            let outline = CABasicAnimation(keyPath: "opacity")
            outline.fromValue = 1; outline.toValue = 0; outline.duration = 0.2
            place.add(outline, forKey: "arrive.outline")
            favicon.add(fade, forKey: "arrive.opacity")
            favicon.add(grow, forKey: "arrive.scale")
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { stroke.removeAnimation(forKey: "search"); return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let box = bounds.insetBy(dx: side / 6, dy: side / 6)
        let radius = side / 6
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let perimeter = 2 * (box.width + box.height - 4 * radius) + 2 * .pi * radius
        if pathLength != perimeter { stroke.removeAnimation(forKey: "search"); pathLength = perimeter }
        for shape in [place, stroke] { shape.frame = bounds; shape.path = path; shape.lineWidth = side / 12 }
        place.lineDashPattern = [2, 3]
        stroke.lineDashPattern = [NSNumber(value: Double(side * 10 / 24)), NSNumber(value: Double(max(1, perimeter - side * 10 / 24)))]
        favicon.frame = bounds
        CATransaction.commit()
        if searching && !still && window != nil {
            if stroke.animation(forKey: "search") == nil {
                let run = CABasicAnimation(keyPath: "lineDashPhase")
                run.fromValue = 0; run.toValue = -perimeter; run.duration = 1.2; run.repeatCount = .infinity
                stroke.add(run, forKey: "search")
            }
        } else { stroke.removeAnimation(forKey: "search") }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stroke.removeAllAnimations() }
        else { needsLayout = true }
    }
}
