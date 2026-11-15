import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Fast

/// The page card's rounded edge has one owner, the stage's mask, in every
/// state (docs/page-corners.md). These walk the layers from the page up to
/// the window, as the `corners` bench verb does in the running app, and
/// fail on a second cut on the same edge or paper lying on it.
@Suite(.serialized)
@MainActor
struct PageCornersTests {
    private func window(_ size: CGSize = CGSize(width: 900, height: 640)) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        content.wantsLayer = true
        window.contentView = content
        return window
    }

    /// A stage with a page on it, in a window, as SwiftUI leaves it.
    private func stage(in window: NSWindow, corner: CGFloat = 10, flatTop: Bool = false,
                       frame: CGRect = CGRect(x: 6.5, y: 6, width: 800, height: 600)) -> (StageView, NSView) {
        let stage = StageView(frame: frame)
        stage.autoresizesSubviews = false
        window.contentView?.addSubview(stage)
        stage.round(corner, flatTop: flatTop)
        let page = NSView(frame: stage.bounds)
        page.wantsLayer = true
        stage.show(page, of: UUID())
        stage.layoutSubtreeIfNeeded()
        return (stage, page)
    }

    private func owners(_ stage: StageView) -> [PageCorners.Cut] {
        PageCorners.cuts(on: stage).filter { $0.kind != "rect" }
    }

    /// One cut on the edge, the stage's own: its corner radius at rest
    /// (cheaper to draw than a mask), its mask while held or making room.
    private func expectOneOwner(_ stage: StageView, _ state: String) {
        let cuts = owners(stage)
        #expect(cuts.count == 1, "\(state): \(cuts)")
        #expect(cuts.first?.isStage == true, "\(state): \(cuts)")
        #expect(cuts.first?.kind == (stage.isHeld ? "mask" : "radius"), "\(state): \(cuts)")
        #expect(PageCorners.verdict(stage, PageCorners.cuts(on: stage)).ok, "\(state)")
        // Never both: a corner radius under a mask is two curves.
        #expect(stage.isHeld ? stage.layer?.cornerRadius == 0 : stage.cuttingMask == nil, "\(state)")
    }

    @Test func atRestTheStageAloneCutsTheCard() {
        let window = window()
        let (stage, page) = stage(in: window)
        #expect(page.superview === stage)
        expectOneOwner(stage, "rest")
        let (flat, _) = self.stage(in: window, flatTop: true, frame: CGRect(x: 20, y: 20, width: 400, height: 300))
        expectOneOwner(flat, "rest under the address bar")
    }

    @Test func heldTheMaskCutsAndLetGoTheCornerAgain() {
        let window = window()
        let (stage, _) = stage(in: window)
        #expect(stage.cuttingMask == nil)
        stage.hold(true)
        #expect(stage.isHeld)
        expectOneOwner(stage, "held")
        #expect(stage.cuttingMask != nil)
        // Made another size while held: drawn there on the same mask.
        stage.frame = CGRect(x: 40, y: 6, width: 700, height: 600)
        stage.layoutSubtreeIfNeeded()
        expectOneOwner(stage, "held, reshaped")
        stage.hold(false)
        #expect(!stage.isHeld)
        expectOneOwner(stage, "let go")
        #expect(stage.cuttingMask == nil)
        #expect(stage.layer?.backgroundColor == nil)
    }

    @Test func roomMadeBesideThePageIsCutByTheStageAlone() {
        let window = window()
        let (stage, _) = stage(in: window)
        let frame = stage.convert(stage.bounds, to: nil)
        let linear = CAMediaTimingFunction(name: .linear)
        stage.preview(CGRect(x: frame.minX, y: frame.minY, width: 400, height: frame.height), duration: 0.2, timing: linear)
        #expect(stage.previewing != nil)
        expectOneOwner(stage, "preview")
        let edge = PageCorners.edge(of: stage) ?? .null
        #expect(abs(edge.width - 400) < 0.5)
        stage.preview(nil, duration: 0, timing: linear)
    }

    /// A tab picked is in at once, as in Arc: nothing steps in from the
    /// tab's side or fades, the page left goes (register #441).
    @Test func aTabPickedIsInAtOnceAndNothingMoves() {
        let window = window()
        let (stage, first) = stage(in: window)
        let next = NSView(frame: stage.bounds)
        next.wantsLayer = true
        stage.show(next, of: UUID())
        #expect(first.superview == nil && next.superview === stage)
        #expect((next.layer?.animationKeys() ?? []).isEmpty)
        #expect(next.layer?.opacity == 1)
        expectOneOwner(stage, "switched")
    }

    @Test func edgeToEdgeNothingSoftCuts() {
        let window = window()
        let (stage, _) = stage(in: window, corner: 0, frame: CGRect(x: 0, y: 0, width: 900, height: 640))
        #expect(stage.cuttingMask == nil)
        #expect(owners(stage).isEmpty)
        #expect(PageCorners.verdict(stage, PageCorners.cuts(on: stage)).ok)
        stage.hold(true)
        expectOneOwner(stage, "held edge to edge")
        stage.hold(false)
        #expect(stage.cuttingMask == nil)
    }

    @Test func underSwiftUIsOwnCoverThePageStepsIn() throws {
        let window = window()
        let (stage, _) = stage(in: window)
        stage.round(10, covered: true)
        #expect(owners(stage).isEmpty)
        #expect(PageCorners.verdict(stage, PageCorners.cuts(on: stage)).ok)
        let path = try #require(stage.cuttingMask?.path)
        let box = path.boundingBox
        let bounds = try #require(stage.layer?.bounds)
        #expect(abs(box.minX - bounds.minX - 1) < 0.01 && abs(bounds.maxX - box.maxX - 1) < 0.01)
    }

    @Test func aSecondCutOnTheSameEdgeIsCaught() throws {
        let window = window()
        let host = NSView(frame: CGRect(x: 6.5, y: 6, width: 800, height: 600))
        host.wantsLayer = true
        window.contentView?.addSubview(host)
        let stage = StageView(frame: host.bounds)
        host.addSubview(stage)
        stage.round(10)
        stage.show(NSView(frame: stage.bounds), of: UUID())
        // What SwiftUI's clipShape on the page did: a mask of its own on the
        // stage's host, on the same outline.
        let clip = CAShapeLayer()
        clip.frame = try #require(host.layer?.bounds)
        clip.path = Reshape.outline(clip.bounds, corner: 10)
        host.layer?.mask = clip
        let cuts = owners(stage)
        #expect(cuts.count == 2)
        #expect(!PageCorners.verdict(stage, PageCorners.cuts(on: stage)).ok)
        // And Core Animation's own corner on a container round the card.
        host.layer?.mask = nil
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        #expect(owners(stage).count == 2)
    }

    @Test func underAPeekTheCardIsNotClippedAndThePaperFades() throws {
        let surface = PeekSurfaceView()
        let window = window()
        surface.frame = CGRect(x: 6, y: 6, width: 860, height: 620)
        window.contentView?.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        let paper = PaperView(frame: surface.host.bounds.insetBy(dx: -1, dy: -1))
        surface.host.addSubview(paper)
        paper.dress(corner: 10, dark: true, band: nil)
        paper.layoutSubtreeIfNeeded()
        let stage = StageView(frame: surface.host.bounds)
        surface.host.addSubview(stage)
        stage.round(10)
        stage.show(NSView(frame: stage.bounds), of: UUID())
        #expect(surface.card.papers.count == 1)
        surface.peek.depth.set(true, animated: false, reducedMotion: false)
        #expect(surface.card.layer?.transform.m11 ?? 1 < 1)
        #expect(surface.card.layer?.masksToBounds == false)
        #expect(surface.card.layer?.mask == nil)
        #expect(paper.receded)
        expectOneOwner(stage, "peek")
        surface.peek.depth.set(false, animated: false, reducedMotion: false)
        #expect(!paper.receded)
        surface.detach()
    }

    @Test func thePaperKeepsClearOfTheEdge() throws {
        let window = window()
        for band in [nil, PaperBand(height: 40, color: .black, dark: true)] {
            for corner: CGFloat in [10, 0] {
                let paper = PaperView(frame: CGRect(x: 5.5, y: 5, width: 802, height: 602))
                window.contentView?.addSubview(paper)
                paper.dress(corner: corner, dark: true, band: band)
                paper.layoutSubtreeIfNeeded()
                let audit = paper.audit
                let inset = try #require(audit["groundInset"] as? Double)
                #expect(inset >= 0.99, "band \(band != nil) corner \(corner): \(audit)")
                #expect(audit["groundClear"] as? Bool == true)
                #expect(audit["shadowCut"] as? Bool == true)
                #expect(audit["hairlineOutside"] as? Bool == true)
                paper.removeFromSuperview()
            }
        }
    }

    @Test func aPageInSwiftUIIsCutByItsStageAlone() async throws {
        let window = window()
        let tab = Tab(bench: true)
        tab.go(to: try #require(URL(string: "data:text/html,<body style='margin:0;background:%23000'>")))
        let host = NSHostingView(rootView: Page(tab: tab, corner: 10).frame(width: 800, height: 600))
        host.frame = CGRect(x: 6.5, y: 6, width: 800, height: 600)
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        host.layoutSubtreeIfNeeded()
        var queue: [NSView] = [host]
        var found: StageView?
        while let view = queue.popLast() {
            if let stage = view as? StageView { found = stage; break }
            queue.append(contentsOf: view.subviews)
        }
        let stage = try #require(found)
        #expect(stage.subviews.contains { $0 === tab.builtPage })
        expectOneOwner(stage, "Page")
        tab.close()
    }
}
