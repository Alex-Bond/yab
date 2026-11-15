import AppKit
import SwiftUI
import Testing
@testable import Fast

/// Feedback #39, "Sidebar is not colored": a column put away and brought
/// out over the page by the edge was a plain card, the Look's color gone.
struct ColumnGroundTests {
    /// The pager's temporary coating used to be absent from the wash's
    /// mirrors, leaving the old drawing/color up until the stage vanished.
    @MainActor @Test func thePicturedRowsAndDoorsFollowTheCardsWash() throws {
        _ = NSApplication.shared
        let room = CGRect(x: 0, y: 0, width: 240, height: 500)
        let context = try #require(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                                            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let picture = try #require(context.makeImage())
        let wash = SpaceWash()
        let old = SpaceWash.Paint(color: .red, grain: 0)
        let new = SpaceWash.Paint(color: .blue, grain: 0)
        let window = NSWindow(contentRect: room, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let stage = PagerStage(band: room, picture: picture, scale: 1, height: room.height)
        stage.frame = room
        try #require(window.contentView).addSubview(stage)
        stage.ground(Color.clear, paint: old, wash: wash)
        stage.doorsRow(CGRect(x: 80, y: 0, width: 160, height: 40), picture: picture, scale: 1,
                       ground: old, wash: wash)
        #expect(wash.grounds.count == 2)
        wash.show(new, opacity: 0.4)
        for ground in wash.grounds {
            #expect(ground.subviews.last?.layer?.opacity == 0.4)
        }
        wash.clear(old, from: 0.6, spring: true, base: new)
        for ground in wash.grounds {
            #expect(ground.subviews.first?.layer?.backgroundColor == NSColor.blue.cgColor)
            #expect(ground.subviews.last?.layer?.animation(forKey: "wash") is CASpringAnimation)
        }
        stage.removeFromSuperview()
        #expect(wash.grounds.isEmpty)
    }

    @MainActor @Test func aCardOverThePageWearsTheBackdrop() {
        let color = Swatch.coral.color(dark: false, custom: .white)
        let tone = Tone(color, lifted: true)
        let ground = Column.ground(floating: true, tone: tone)
        #expect(ground == tone)
        #expect(ground?.page.hex == "F2837C")
    }

    @MainActor @Test func dockedTheWindowsBackdropShowsThrough() {
        let tone = Tone(Swatch.sky.color(dark: true, custom: .white), lifted: true)
        #expect(Column.ground(floating: false, tone: tone) == nil)
    }

    @MainActor @Test func edgeToEdgeTheCardKeepsItsPlainGround() {
        #expect(Column.ground(floating: true, tone: nil) == nil)
    }

    /// The card's color turned on SwiftUI's own animation, a third of a
    /// second on the main thread, while the window turned on the row's
    /// spring: it now turns in Core Animation on that same spring, the new
    /// color under the old from the switch's own frame.
    @MainActor @Test func aCardsGroundTurnsOnTheRowsSpring() throws {
        let view = CardGroundView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        let old = SpaceWash.Paint(color: .red, grain: 0), new = SpaceWash.Paint(color: .blue, grain: 0)
        view.given(old)
        view.clear(old, from: 1, spring: true, duration: 0, base: new)
        let base = try #require(view.subviews.first?.layer), over = try #require(view.subviews.last?.layer)
        #expect(base.backgroundColor == NSColor.blue.cgColor)
        // Opaque, the new color stays whole under the old: under it is the page.
        #expect(base.opacity == 1)
        #expect(base.animation(forKey: "space-cover") == nil)
        let spring = try #require(over.animation(forKey: "wash") as? CASpringAnimation)
        #expect(spring.stiffness == CGFloat(SpacePaging.stiffness))
        #expect(spring.damping == CGFloat(SpacePaging.friction))
        #expect(spring.fromValue as? Float == 1)
        #expect(over.opacity == 0)
        // SwiftUI's next pass with the paint it had leaves the switch's alone.
        view.given(old)
        #expect(base.backgroundColor == NSColor.blue.cgColor)
    }

    /// Two opaque colors cross straight in the window too, so the card and
    /// the docked column turn alike: the coating no longer gives way to the
    /// glass's gray under an opaque color halfway over it.
    @MainActor @Test func opaqueColorsCrossStraightInTheWindow() {
        _ = NSApplication.shared
        let backdrop = WindowBackdropView(frame: .zero)
        backdrop.wear(SpaceWash.Paint(color: .red, grain: 0))
        backdrop.overOpacity = 1
        backdrop.setCover(0.5)
        #expect(backdrop.coating.layer?.opacity == 1)
        // Under a see-through color it gives way as much as that covers:
        // with half of one at half opacity over it, two thirds, so the two
        // are as opaque together as their mix.
        backdrop.overOpacity = 0.5
        backdrop.setCover(0.5)
        #expect(abs((backdrop.coating.layer?.opacity ?? 0) - 2.0 / 3) < 0.001)
    }

    /// The same see-through color on either side of a switch stays as
    /// opaque all the way: given way by the cover alone, the two were
    /// see-through at once mid-way, and the page under the card came up
    /// between them, the card a tenth darker while the fingers held.
    @MainActor @Test func theSameSeeThroughColorStaysAsOpaqueAcrossASwitch() {
        for alpha: Float in [0.3, 0.6, 0.9, 1] {
            for step in 0...10 {
                let cover = Float(step) / 10
                let base = SpaceWash.given(cover, alpha: alpha, over: alpha)
                let together = cover * alpha + base * (1 - cover * alpha)
                #expect(abs(together - alpha) < 0.0001)
            }
        }
    }

    /// On the way too: the ground's opacity is animated along the mix, on
    /// the row's spring and on a curve, not between its two ends alone.
    @MainActor @Test func theWayIsTheMixToo() throws {
        for animation in [SpaceWash.coverAnimation(alpha: 0.5, over: 0.5, from: 1, to: 0),
                          SpaceWash.coverAnimation(alpha: 0.5, over: 0.5, from: 0, to: 1, duration: 0.3,
                                                   timing: CAMediaTimingFunction(name: .linear))] {
            let frames = try #require(animation as? CAKeyframeAnimation)
            let values = try #require(frames.values as? [NSNumber]).map(\.floatValue)
            let times = try #require(frames.keyTimes).map(\.doubleValue)
            #expect(values.count == times.count)
            #expect(times.first == 0 && times.last == 1)
            // Every value is one the mix asks for at some cover: together
            // with that cover, as opaque as either color alone.
            for value in values {
                let covers = stride(from: Float(0), through: 1, by: 0.001)
                #expect(covers.contains { abs(SpaceWash.given($0, alpha: 0.5, over: 0.5) - value) < 0.002 })
            }
        }
        let spring = try #require(SpaceWash.coverAnimation(alpha: 0.5, over: 0.5, from: 1, to: 0) as? CAKeyframeAnimation)
        let ends = try #require(spring.values as? [NSNumber]).map(\.floatValue)
        #expect(abs((ends.first ?? 1) - 0) < 0.001)
        #expect(abs((ends.last ?? 0) - 0.5) < 0.001)
    }

    /// Two colors mix as far as the row has gone, an opaque one over a
    /// see-through one too: the ground stays as it is and is covered.
    @MainActor @Test func colorsMixAsFarAsTheRowHasGone() {
        let base = SpaceWash.given(0.25, alpha: 0.5, over: 1)
        #expect(base == 0.5)
        let together = 0.25 * 1 + base * (1 - 0.25)
        #expect(abs(together - (0.5 + 0.25 * (1 - 0.5))) < 0.0001)
    }
}
