import AppKit
import Testing
@testable import Fast

/// The way into hiding and back out, as the system's picture in picture
/// does it (docs/float.md, "What the tab looks like").
@MainActor
struct FloatTuckLookTests {
    typealias Look = Floater.TuckLook

    @Test func outAndTuckedAreTheEnds() {
        #expect(Look.at(0, out: false) == Look(controls: 1, blur: 0, dark: 0, tab: 0, reach: 0))
        #expect(Look.at(1, out: false) == Look(controls: 0, blur: 1, dark: Look.darkest, tab: 1, reach: 1))
        #expect(Look.at(1, out: true) == Look(controls: 0, blur: 1, dark: Look.darkest, tab: 1, reach: 1))
        #expect(Look.at(0, out: true) == Look(controls: 1, blur: 0, dark: 0, tab: 0, reach: 0))
    }

    @Test func goingTheButtonsGoFirstThenBlurThenGrey() {
        // 0.1 s after letting go: the buttons gone, the blur on its way, no
        // grey yet, no tab.
        let early = Look.at(0.17, out: false)
        #expect(early.controls == 0)
        #expect(early.blur > 0.05 && early.blur < 0.5)
        #expect(early.dark == 0)
        #expect(early.tab == 0)
        // 0.37 s: blurred, grey on its way, the tab out.
        let later = Look.at(0.77, out: false)
        #expect(later.blur == 1)
        #expect(later.tab == 1)
        #expect(later.dark > 0.3 && later.dark < Look.darkest)
        var last = Look.at(0, out: false)
        for step in 1...20 {
            let look = Look.at(CGFloat(step) / 20, out: false)
            #expect(look.blur >= last.blur && look.dark >= last.dark && look.tab >= last.tab && look.reach >= last.reach)
            #expect(look.controls <= last.controls)
            last = look
        }
    }

    @Test func comingOutTheGreyLiftsWhileThePictureIsStillBlurred() {
        // A fifth of the way out: the tab gone back, the grey half gone,
        // still blurred.
        let look = Look.at(0.8, out: true)
        #expect(look.tab == 0)
        #expect(look.dark < 0.5 && look.dark > 0.1)
        #expect(look.blur == 1)
        #expect(look.controls == 0)
        // Clear by seven tenths.
        #expect(Look.at(0.5, out: true).blur > 0.1)
        #expect(Look.at(0.3, out: true).blur == 0)
    }

    @Test func safarisGreyLeavesAThirdOfThePicture() {
        #expect(abs(Look.darkest - 0.642) < 0.001)
    }

    @Test func oneSpringForGoingAndComingBack() {
        for kind in [Floater.Motion.park, .back] {
            let (half, _) = Floater.progress(kind, 0.22)
            let (most, _) = Floater.progress(kind, 0.4)
            let (still, _) = Floater.progress(kind, 0.8)
            #expect(abs(half - 0.5) < 0.03)
            #expect(abs(most - 0.8) < 0.03)
            #expect(still > 0.98)
        }
    }
}
