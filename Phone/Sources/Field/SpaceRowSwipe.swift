import SwiftUI
import UIKit

extension Metrics {
    enum SpaceSwipe {
        static let edge: CGFloat = 28
    }
}

/// Ownership is chosen at touchdown, before either native scroll view begins.
enum SpaceSwipeOwner {
    case page, row

    static func at(_ x: CGFloat, width: CGFloat, overSwipeRow: Bool) -> Self {
        !overSwipeRow || x <= Metrics.SpaceSwipe.edge || x >= width - Metrics.SpaceSwipe.edge ? .page : .row
    }
}

/// Explicitly mark only content with native swipe actions. Frames are read at
/// touchdown, so scrolling, folded folders and reused list cells stay current.
struct SpaceSwipeRowRegion: UIViewRepresentable {
    func makeUIView(context: Context) -> SpaceSwipeRowRegionView { SpaceSwipeRowRegionView() }
    func updateUIView(_ view: SpaceSwipeRowRegionView, context: Context) {}
}

final class SpaceSwipeRowRegionView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func contains(_ point: CGPoint, in view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0 else { return false }
        let local = view.convert(point, from: view.superview)
        if view.clipsToBounds && !view.bounds.contains(local) { return false }
        // List insets and nested-folder indentation still belong to the row.
        if view is UICollectionViewCell || view is UITableViewCell,
           view.bounds.contains(local), hasRegion(in: view) { return true }
        if view is SpaceSwipeRowRegionView, view.bounds.contains(local), !view.bounds.isEmpty { return true }
        return view.subviews.contains { contains(local, in: $0) }
    }

    private static func hasRegion(in view: UIView) -> Bool {
        guard !view.isHidden, view.alpha > 0, !view.bounds.isEmpty else { return false }
        return view is SpaceSwipeRowRegionView || view.subviews.contains { hasRegion(in: $0) }
    }
}

/// Observe the pager's touches without recognizing, canceling a button, or
/// claiming a vertical pan. The pager's own pan remains native outside swipeable rows.
struct SpacePagingTouchGate: UIViewRepresentable {
    func makeUIView(context: Context) -> SpacePagingGateView { SpacePagingGateView() }
    func updateUIView(_ view: SpacePagingGateView, context: Context) { view.install() }
    static func dismantleUIView(_ view: SpacePagingGateView, coordinator: ()) { view.uninstall() }
}

final class SpacePagingGateView: UIView {
    private let gate: SpacePagingTouchObserver

    override init(frame: CGRect) {
        gate = SpacePagingTouchObserver()
        super.init(frame: .zero)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() { super.didMoveToWindow(); if window == nil { uninstall() } else { install() } }
    override func didMoveToSuperview() { super.didMoveToSuperview(); install() }

    func install() {
        guard window != nil else { return }
        var parent = superview
        while let view = parent {
            if let scroll = view as? UIScrollView {
                guard gate.view !== scroll else { return }
                uninstall()
                gate.scroll = scroll
                scroll.addGestureRecognizer(gate)
                return
            }
            parent = view.superview
        }
    }

    func uninstall() {
        gate.finish()
        gate.view?.removeGestureRecognizer(gate)
        gate.scroll = nil
    }
}

final class SpacePagingTouchObserver: UIGestureRecognizer {
    weak var scroll: UIScrollView?
    private var disabledPan = false
    private var tracking = false

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !tracking, let scroll, let touch = touches.first else { return }
        tracking = true
        let point = touch.location(in: scroll)
        let overRow = scroll.subviews.contains { SpaceSwipeRowRegionView.contains(point, in: $0) }
        let owner = SpaceSwipeOwner.at(point.x - scroll.bounds.minX, width: scroll.bounds.width, overSwipeRow: overRow)
        if owner == .row, scroll.panGestureRecognizer.isEnabled {
            disabledPan = true
            scroll.panGestureRecognizer.isEnabled = false
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(); state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(); state = .failed }
    override func reset() { finish(); super.reset() }

    func finish() {
        if disabledPan { scroll?.panGestureRecognizer.isEnabled = true }
        disabledPan = false
        tracking = false
    }
}

/// A tab's row swipes as Mail's do, with the system's own actions: right
/// for Pin and Keep (or Unkeep), left for Close. The pager's pan is off
/// for a finger that went down on the row away from the edges, so the row's
/// swipe gets it (SpacePagingTouchObserver).
struct SpaceTabSwipes: ViewModifier {
    @Environment(AppModel.self) private var app
    let tab: Tab

    func body(content: Content) -> some View {
        let column = ColumnState.of(app)
        content
            .background(SpaceSwipeRowRegion())
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if !tab.isPrivate {
                    if tab.place == .kept {
                        action("Unkeep", .anchor, tint: Color(uiColor: .systemBlue), id: "keep") { column.unkeep(tab.id) }
                    } else {
                        action("Keep", .yabAnchor, tint: Color(uiColor: .systemBlue), id: "keep") { column.keep(tab.id) }
                    }
                    action("Pin", .pin, tint: ChatInk.pin, id: "pin") { column.pin(tab.id) }
                }
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                action("Close", .yabTabX, tint: Color(uiColor: .systemRed), id: "close") { column.close(tab.id) }
            }
    }

    private func action(_ title: String, _ glyph: MacGlyph, tint: Color, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label { Text(title) } icon: {
                if let image = UIImage.menuGlyph(glyph) { Image(uiImage: image) }
            }
        }
        .tint(tint)
        .accessibilityIdentifier("newtab.swipe.\(id).\(tab.id)")
    }
}

/// Search results cover the native pager, but horizontal swipes still
/// select its neighboring space. Vertical result scrolling keeps its finger.
enum SpaceSearchPaging {
    static func destination(from page: String?, pages: [String], translation: CGSize) -> String? {
        guard let page, let index = pages.firstIndex(of: page),
              abs(translation.width) >= 60,
              abs(translation.width) > abs(translation.height) * 1.5 else { return nil }
        let next = index + (translation.width < 0 ? 1 : -1)
        return pages.indices.contains(next) ? pages[next] : nil
    }
}
