import AppKit
import SwiftUI

/// Keep Chrome's 200-point navigation width as the detail pane resizes.
/// The divider remains draggable, with enough room for both sides.
struct DevApplicationSplit: NSViewRepresentable {
    var sidebar: AnyView
    var detail: AnyView
    private func styled(_ view: AnyView, _ scheme: ColorScheme) -> AnyView {
        AnyView(view.font(.system(size: 11.5)).foregroundStyle(Palette.ink).background(Palette.ground).environment(\.colorScheme, scheme))
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSSplitView {
        let split = NSSplitView(); split.isVertical = true; split.dividerStyle = .thin; split.delegate = context.coordinator
        let left = NSHostingView(rootView: styled(sidebar, context.environment.colorScheme)), right = NSHostingView(rootView: styled(detail, context.environment.colorScheme))
        left.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
        right.frame = NSRect(x: 201, y: 0, width: 600, height: 400)
        split.addSubview(left); split.addSubview(right)
        return split
    }
    func updateNSView(_ split: NSSplitView, context: Context) {
        (split.subviews.first as? NSHostingView<AnyView>)?.rootView = styled(sidebar, context.environment.colorScheme)
        (split.subviews.last as? NSHostingView<AnyView>)?.rootView = styled(detail, context.environment.colorScheme)
    }
    @MainActor final class Coordinator: NSObject, NSSplitViewDelegate {
        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { 145 }
        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat { max(145, min(340, splitView.bounds.width - 181)) }
        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }
        func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { view !== splitView.subviews.first }
    }
}
