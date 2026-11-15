import AppKit
import Testing
@testable import Fast

// Where the tabs across the top are (KeySky.place): measured in their run,
// taken to the window through an AppKit view under it as they are read, so
// the strip coming down from past the window's top and the run scrolling
// move them with it. SwiftUI's global frames inside the run were counted
// once and kept, a strip's height off from launch on.
@MainActor
struct StripPlacesTests {
    /// A window with the rows' ground over all of it, and a run of tabs
    /// 1000 wide in a scroll view 300 wide at (100, 20), as the strip has it.
    @MainActor
    final class Rig {
        let window: NSWindow
        let sky = KeySky()
        let ground: NSView
        let scroll: NSScrollView
        let anchor = StripAnchorView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        let box = KeySky.Anchor(.run)

        init() {
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            let root = Flipped(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            window.contentView = root
            ground = Flipped(frame: root.bounds)
            root.addSubview(ground)
            scroll = NSScrollView(frame: NSRect(x: 100, y: 20, width: 300, height: 40))
            scroll.contentView = FlippedClip()
            let run = Flipped(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
            scroll.documentView = run
            run.addSubview(anchor)
            root.addSubview(scroll)
            sky.groundView = ground
            box.view = anchor
            sky.room(box)
            anchor.sky = sky
        }

        func scrolled(to x: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: x, y: 0))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    final class Flipped: NSView {
        override var isFlipped: Bool { true }
    }

    final class FlippedClip: NSClipView {
        override var isFlipped: Bool { true }
    }

    let tab = CGRect(x: 50, y: 6, width: 120, height: 28)

    @Test func aTabAcrossTheTopIsWhereItsRunIsInTheWindow() {
        let rig = Rig()
        let id = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        #expect(rig.sky.place(id) == CGRect(x: 150, y: 26, width: 120, height: 28))
        // In the window's SwiftUI space, which starts where the ground does.
        rig.sky.ground = CGPoint(x: 0, y: 28)
        #expect(rig.sky.place(id) == CGRect(x: 150, y: 54, width: 120, height: 28))
    }

    @Test func itComesDownWithTheStripWithoutBeingMeasuredAgain() {
        // Laid out while the strip was still up past the window's top, as
        // at launch: then the strip came down and nothing measured again.
        let rig = Rig()
        rig.scroll.setFrameOrigin(NSPoint(x: 100, y: -20))
        let id = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        #expect(rig.sky.place(id)?.minY == -14)
        rig.scroll.setFrameOrigin(NSPoint(x: 100, y: 20))
        #expect(rig.sky.place(id) == CGRect(x: 150, y: 26, width: 120, height: 28))
        #expect(rig.sky.stripTab(at: CGPoint(x: 200, y: 40), among: [id]) == id)
        #expect(rig.sky.stripTab(at: CGPoint(x: 200, y: 0), among: [id]) == nil)
    }

    @Test func itGoesAlongAsTheRunScrolls() {
        let rig = Rig()
        let id = UUID()
        let far = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        rig.sky.lay(far, CGRect(x: 600, y: 6, width: 120, height: 28), in: rig.box, by: UUID())
        // Out past the run's end: where it would be, but not seen, and a
        // press over the plus beyond the run is not on it.
        #expect(rig.sky.seen(far) == nil)
        #expect(rig.sky.stripTab(at: CGPoint(x: 720, y: 40), among: [id, far]) == nil)
        rig.scrolled(to: 100)
        #expect(rig.sky.place(id) == CGRect(x: 50, y: 26, width: 120, height: 28))
        // Half of it scrolled under the run's leading end.
        #expect(rig.sky.seen(id) == CGRect(x: 100, y: 26, width: 70, height: 28))
        #expect(rig.sky.stripTab(at: CGPoint(x: 80, y: 40), among: [id, far]) == nil)
        #expect(rig.sky.stripTab(at: CGPoint(x: 120, y: 40), among: [id, far]) == id)
        rig.scrolled(to: 500)
        #expect(rig.sky.seen(far) == CGRect(x: 200, y: 26, width: 120, height: 28))
        #expect(rig.sky.stripTab(at: CGPoint(x: 260, y: 40), among: [id, far]) == far)
    }

    @Test func aQuestionsTabMovingIsHeardWhenTheRunScrolls() {
        let rig = Rig()
        let id = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        rig.sky.watched = id
        let before = rig.sky.moved
        rig.scrolled(to: 40)
        rig.sky.shifted()
        #expect(rig.sky.moved > before)
    }

    @Test func onlyThePillThatSaidSoTakesItBack() {
        let rig = Rig()
        let id = UUID()
        let pill = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: pill)
        rig.sky.unlay(id, by: UUID())
        #expect(rig.sky.place(id) != nil)
        rig.sky.unlay(id, by: pill)
        #expect(rig.sky.place(id) == nil)
    }

    @Test func theColumnsRowTakesOverFromTheStrip() {
        let rig = Rig()
        let id = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        let row = CGRect(x: 8, y: 120, width: 220, height: 32)
        rig.sky.lay(id, row)
        #expect(rig.sky.place(id) == row)
        #expect(rig.sky.stripTab(at: CGPoint(x: 20, y: 130), among: [id]) == nil)
        #expect(rig.sky.places[id] == row)
    }

    @Test func aStripMadeAgainDoesNotTakeTheOthersTabsWithIt() {
        // A window's strip made again (its first tab, the tabs changing
        // sides): for a moment two runs, the one going and the one coming.
        // The one coming holds; the one going, still saying where its tabs
        // are as it fades, takes only its own word when it goes. Taking
        // the tab's place with it left a second window's tabs nowhere.
        let rig = Rig()
        let id = UUID()
        let going = rig.box
        let gone = UUID()
        rig.sky.lay(id, tab, in: going, by: gone)
        let coming = KeySky.Anchor(.run)
        let view = StripAnchorView(frame: NSRect(x: 0, y: 0, width: 1000, height: 40))
        let host = Flipped(frame: NSRect(x: 100, y: 60, width: 1000, height: 40))
        rig.window.contentView?.addSubview(host)
        host.addSubview(view)
        coming.view = view
        rig.sky.lay(id, tab, in: coming, by: UUID())
        let held = CGRect(x: 150, y: 66, width: 120, height: 28)
        #expect(rig.sky.place(id) == held)
        // The one going, a frame later in its fade, then gone.
        rig.sky.lay(id, tab.offsetBy(dx: 0, dy: -4), in: going, by: gone)
        #expect(rig.sky.place(id) == held)
        rig.sky.unlay(id, by: gone)
        #expect(rig.sky.place(id) == held)
        #expect(rig.sky.stripTab(at: CGPoint(x: 200, y: 80), among: [id]) == id)
        #expect(rig.sky.runScroll === rig.scroll)
    }

    @Test func aRunGoneFromTheWindowPlacesNothing() {
        let rig = Rig()
        let id = UUID()
        rig.sky.lay(id, tab, in: rig.box, by: UUID())
        rig.anchor.removeFromSuperview()
        #expect(rig.sky.place(id) == nil)
        #expect(rig.sky.places[id] == nil)
    }

    @Test func aPointOfTheWindowIsInTheTabsSpace() {
        let rig = Rig()
        rig.sky.ground = CGPoint(x: 0, y: 28)
        // AppKit's, from the window's bottom left: 600 high.
        let at = rig.sky.spot(NSPoint(x: 200, y: 560), in: rig.window)
        #expect(at == CGPoint(x: 200, y: 68))
        let other = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 10, height: 10),
                             styleMask: [.borderless], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        #expect(rig.sky.spot(NSPoint(x: 1, y: 1), in: other) == nil)
    }

    @Test func onlyWhatTakesNoClicksIsSeeThroughToAHand() {
        #expect(TearRules.seeThrough(executable: "blackout", bundle: nil))
        #expect(TearRules.seeThrough(executable: "NotificationCenter", bundle: "com.apple.notificationcenterui"))
        // A password dialog over everything takes the press.
        #expect(!TearRules.seeThrough(executable: "SecurityAgent", bundle: "com.apple.SecurityAgent"))
        #expect(!TearRules.seeThrough(executable: "Finder", bundle: "com.apple.finder"))
        #expect(!TearRules.seeThrough(executable: nil, bundle: nil))
    }
}
