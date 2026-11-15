import SwiftUI
import UIKit
import os

/// A real scroll viewport, including its accessibility bounds and native
/// pan. SwiftUI's overflow card exposed the union of its offscreen rows.
struct NewTabScroll<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let scrolled: (CGFloat) -> Void
    let pulled: (CGFloat) -> Void
    let released: (CGFloat, CGFloat) -> Void

    func makeUIViewController(context: Context) -> NewTabScrollController {
        let controller = NewTabScrollController()
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: NewTabScrollController, context: Context) {
        controller.scrolled = scrolled
        controller.pulled = pulled
        controller.released = released
        controller.update(AnyView(content
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.dynamicTypeSize, context.environment.dynamicTypeSize)))
    }
}

@MainActor
final class NewTabScrollController: UIViewController, UIScrollViewDelegate {
    private let scroll = UIScrollView()
    private let host = UIHostingController(rootView: AnyView(EmptyView()))
    private var positioned = false
    private var topPull: CGFloat = 0
    private var startOffset: CGFloat = 0
    private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "field.scroll")
    var scrolled: (CGFloat) -> Void = { _ in }
    var pulled: (CGFloat) -> Void = { _ in }
    var released: (CGFloat, CGFloat) -> Void = { _, _ in }

    override func loadView() {
        scroll.backgroundColor = .clear
        scroll.clipsToBounds = true
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.accessibilityIdentifier = "newtab.card"
        scroll.delegate = self
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.view.backgroundColor = .clear
        addChild(host)
        scroll.addSubview(host.view)
        host.didMove(toParent: self)
    }

    func update(_ content: AnyView) {
        host.rootView = content
        if isViewLoaded { view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
        let atBottom = abs(scroll.contentOffset.y - max(0, scroll.contentSize.height - scroll.bounds.height)) < 1
        let size = host.sizeThatFits(in: CGSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude))
        host.view.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: size.height)
        if scroll.contentSize != host.view.bounds.size { scroll.contentSize = host.view.bounds.size }
        // Start nearest the field, like defaultScrollAnchor(.bottom), and
        // preserve that anchor when a live text-size change grows the rows.
        if !positioned || (atBottom && !scroll.isDragging && !scroll.isDecelerating) {
            positioned = true
            let offset = CGPoint(x: 0, y: max(0, size.height - scroll.bounds.height))
            if scroll.contentOffset != offset { scroll.contentOffset = offset }
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        topPull = 0
        startOffset = max(0, scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
        if LaunchOptions.current.isTestRun {
            log.info("New Tab native pan begin offset=\(self.startOffset, privacy: .public)")
        }
    }

    /// UIKit rubber-bands the content offset. The prototype's close distance
    /// is the finger's travel past the top, measured in the stationary window.
    private func pull(in scrollView: UIScrollView) -> CGFloat {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        guard offset < 0 else { return 0 }
        return max(0, scrollView.panGestureRecognizer.translation(in: scrollView.window).y - startOffset)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        if scrollView.isDragging {
            let pull = pull(in: scrollView)
            topPull = max(topPull, pull)
            pulled(pull)
            scrolled(offset)
        } else {
            // Layout can set the initial anchor during a SwiftUI update.
            DispatchQueue.main.async { [weak self] in self?.scrolled(offset) }
        }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        let pull = max(topPull, pull(in: scrollView))
        let fingerSpeed = scrollView.panGestureRecognizer.velocity(in: scrollView.window).y
        if LaunchOptions.current.isTestRun {
            log.info("New Tab native pan end offset=\(scrollView.contentOffset.y, privacy: .public) finger=\(scrollView.panGestureRecognizer.translation(in: scrollView.window).y, privacy: .public) start=\(self.startOffset, privacy: .public) pull=\(pull, privacy: .public) speed=\(fingerSpeed, privacy: .public)")
        }
        released(pull, fingerSpeed)
        topPull = 0
    }
}
