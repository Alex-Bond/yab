import AppKit
import QuartzCore
import Testing
@testable import Fast

@Suite(.serialized)
@MainActor
struct PeekDepthTests {
    private func scene() -> (StageView, NSView, PeekDepth) {
        let stage = StageView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        stage.wantsLayer = true
        stage.autoresizesSubviews = false
        let page = NSView(frame: stage.bounds)
        stage.show(page, of: UUID())
        // No window is needed for these layer invariants. StageView only
        // attaches its page in a window, so attach the fixture explicitly.
        stage.addSubview(page)
        let depth = PeekDepth()
        depth.bind(surface: stage)
        return (stage, page, depth)
    }

    @Test func openingAndClosingNeverResizeTheDocument() throws {
        let (stage, page, depth) = scene()
        let layer = try #require(stage.layer)
        let frame = page.frame, bounds = page.bounds, stageFrame = stage.frame
        StageView.resizes = 0
        for _ in 0..<50 {
            depth.set(true, animated: true, reducedMotion: false)
            #expect(layer.transform.m11 == (1 - 2 * PeekDepth.inset / 1000))
            #expect(layer.animation(forKey: PeekDepth.key) is CASpringAnimation)
            depth.set(false, animated: true, reducedMotion: false)
            #expect(CATransform3DIsIdentity(layer.transform))
        }
        #expect(page.frame == frame)
        #expect(page.bounds == bounds)
        #expect(stage.frame == stageFrame)
        #expect(StageView.resizes == 0)
    }

    @Test func scaleKeepsTheCenterForAppKitAndCenterAnchors() {
        let layer = CALayer()
        layer.bounds = CGRect(x: 23, y: 47, width: 1000, height: 700)
        for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
            layer.anchorPoint = anchor
            let t = PeekDepth.insetTransform(layer, inset: PeekDepth.inset)
            let x = layer.bounds.width * (0.5 - anchor.x)
            let y = layer.bounds.height * (0.5 - anchor.y)
            #expect(abs(x * t.m11 + t.m41 - x) < 0.0001)
            #expect(abs(y * t.m22 + t.m42 - y) < 0.0001)
        }
    }

    @Test func wideAndTallCardsHaveIdenticalInsetsOnEveryEdge() {
        let layer = CALayer()
        for size in [CGSize(width: 1000, height: 700), CGSize(width: 700, height: 1000), CGSize(width: 400, height: 1200)] {
            layer.bounds.size = size
            for anchor in [CGPoint.zero, CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
                layer.anchorPoint = anchor
                let t = PeekDepth.insetTransform(layer, inset: PeekDepth.inset)
                let gaps = [size.width * anchor.x * (1 - t.m11) + t.m41,
                            size.width * (1 - anchor.x) * (1 - t.m11) - t.m41,
                            size.height * anchor.y * (1 - t.m22) + t.m42,
                            size.height * (1 - anchor.y) * (1 - t.m22) - t.m42]
                #expect(gaps.allSatisfy { abs($0 - PeekDepth.inset) < 0.0001 })
            }
        }
    }

    @Test func finalPaddingMatchesBesideEitherSidebarAndBelowTheStrip() {
        let layer = CALayer()
        layer.bounds.size = CGSize(width: 1000, height: 700)
        let paddings: [[CGFloat]] = [[0, 6, 6, 6], [6, 6, 0, 6], [6, 0, 6, 6]]
        for padding in paddings {
            for topAtMaxY in [false, true] {
                layer.transform = PeekDepth.insetTransform(layer, inset: PeekDepth.inset, padding: padding, topAtMaxY: topAtMaxY)
                let gaps = zip(PeekDepth.drawnInsets(layer, topAtMaxY: topAtMaxY), padding).map { $0.0 + $0.1 }
                #expect(gaps.allSatisfy { abs($0 - 18) < 0.0001 })
            }
        }
    }

    @Test func tabSwitchRestoresThePreviousStageAndRemovesItsAnimation() throws {
        let (old, oldPage, depth) = scene()
        let (next, _, _) = scene()
        depth.set(true, animated: true, reducedMotion: false)
        depth.bind(surface: next)
        #expect(CATransform3DIsIdentity(try #require(old.layer).transform))
        #expect(old.layer?.animation(forKey: PeekDepth.key) == nil)
        #expect(oldPage.superview === old)
        depth.set(true, animated: false, reducedMotion: false)
        #expect(next.layer?.transform.m11 == (1 - 2 * PeekDepth.inset / 1000))
    }

    @Test func reducedMotionAndDropLeaveNoTransformOrAnimation() throws {
        let (stage, _, depth) = scene()
        depth.set(true, animated: true, reducedMotion: false)
        depth.set(true, animated: true, reducedMotion: true)
        let layer = try #require(stage.layer)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: PeekDepth.key) == nil)
        depth.set(true, animated: true, reducedMotion: false)
        depth.bind(surface: nil)
        #expect(CATransform3DIsIdentity(layer.transform))
        #expect(layer.animation(forKey: PeekDepth.key) == nil)
    }

    @Test func aRealResizeRecentersWithoutResizingThePage() throws {
        let (stage, page, depth) = scene()
        let frame = page.frame
        depth.set(true, animated: false, reducedMotion: false)
        stage.layer?.bounds.size = CGSize(width: 1200, height: 800)
        depth.refresh()
        let layer = try #require(stage.layer)
        let expected = PeekDepth.insetTransform(layer, inset: PeekDepth.inset)
        #expect(CATransform3DEqualToTransform(layer.transform, expected))
        #expect(page.frame == frame)
    }

    @Test func fullCardCarrierScalesAndPeekRemainsItsSibling() throws {
        let surface = PeekSurfaceView()
        surface.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        surface.layoutSubtreeIfNeeded()
        let page = NSView(frame: surface.host.bounds)
        surface.host.addSubview(page)
        let before = page.frame
        surface.peek.depth.set(true, animated: true, reducedMotion: false)
        #expect(surface.card.layer?.transform.m11 == (1 - 2 * PeekDepth.inset / 1000))
        // The card is never clipped at the page's outline: the stage alone
        // cuts that edge (docs/page-corners.md).
        #expect(surface.card.layer?.masksToBounds == false)
        #expect(surface.card.layer?.mask == nil)
        #expect(CATransform3DIsIdentity(try #require(surface.peek.layer).transform))
        #expect(surface.peek.superview === surface.card.superview)
        #expect(surface.shade.superview === surface.card)
        #expect(surface.card.subviews.last === surface.shade)
        #expect(surface.shade.hitTest(.zero) == nil)
        #expect(page.frame == before)
        surface.detach()
        #expect(CATransform3DIsIdentity(try #require(surface.card.layer).transform))
        #expect(surface.card.layer?.masksToBounds == false)
    }
}
