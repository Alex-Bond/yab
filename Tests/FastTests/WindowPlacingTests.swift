import Foundation
import Testing
@testable import Fast

// Where a new window opens when nothing says where (WindowPlacing): on the
// screen of the window it was asked from, a step right and down from it.
struct WindowPlacingTests {
    @Test func aPrivatePurposeNeverInvokesTheNormalRestoreClosure() {
        let normalIDs = [UUID(), UUID()]
        var original = normalIDs
        var events: [String] = []
        var privateRows: [UUID] = []
        BrowserWindowPurpose.privateOnly.begin(normal: {
            events.append("restore normal pins, kept and today")
            original.removeAll()
        }, privateOnly: {
            privateRows.append(UUID())
            events.append("private seed")
        })
        #expect(original == normalIDs)
        #expect(privateRows.count == 1)
        #expect(events == ["private seed"])
    }

    @Test func normalPurposeKeepsItsExistingRestoreRoute() {
        var events: [String] = []
        BrowserWindowPurpose.normal.begin(normal: {
            events.append("normal restore")
        }, privateOnly: {
            events.append("private seed")
        })
        #expect(events == ["normal restore"])
    }

    @Test func privateIdentitySurvivesTheLastTabAndCannotBeClearedByANormalCaller() {
        #expect(BrowserWindowPurpose.privateOnly.isPrivate(active: nil))
        #expect(BrowserWindowPurpose.privateOnly.isPrivate(active: false))
        #expect(BrowserWindowPurpose.privateOnly.isPrivate(active: true))
        #expect(!BrowserWindowPurpose.normal.isPrivate(active: nil))
        #expect(!BrowserWindowPurpose.normal.isPrivate(active: false))
        #expect(BrowserWindowPurpose.normal.isPrivate(active: true))
    }

    /// A laptop's screen, and a 4K one over it, its menu bar 30 high and
    /// its room all the rest: the Mac where every new window came up on
    /// the laptop's screen, out of sight (Oct 9).
    let laptop = (frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 0, width: 1512, height: 949))
    let top = (frame: CGRect(x: -276, y: 982, width: 1920, height: 1080), visible: CGRect(x: -276, y: 982, width: 1920, height: 1050))
    let size = CGSize(width: 1080, height: 730)

    var screens: [(frame: CGRect, visible: CGRect)] { [laptop, top] }

    @Test func restoringASliverOnTheLaptopDoesNotShrinkTheWindowAboveIt() {
        let saved = CGRect(x: 100, y: 940, width: 1700, height: 1000)
        let restored = WindowPlacing.fitting(saved, screens: screens.map(\.visible), fallback: laptop.visible)
        #expect(restored == CGRect(x: top.visible.maxX - saved.width, y: top.visible.minY,
                                  width: saved.width, height: saved.height))
        #expect(restored.size == saved.size)
        #expect(WindowPlacing.fitting(saved, in: laptop.visible).size != saved.size)
    }

    @Test func repeatedRestoreKeepsAMaximizedFrameAndAnOrdinaryFrame() {
        for saved in [top.visible, CGRect(x: 100, y: 1050, width: 1200, height: 800)] {
            var frame = saved
            for _ in 0..<10 {
                frame = WindowPlacing.fitting(frame, screens: screens.map(\.visible), fallback: laptop.visible)
                #expect(frame == saved)
            }
        }
    }

    @Test func aFrameManyScreensWideComesBackOnTheScreen() {
        // 0.43.1: 22,065 pt wide at x=-20145 on a 1,920 pt screen.
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let saved = CGRect(x: -20145, y: 100, width: 22065, height: 800)
        let restored = WindowPlacing.fitting(saved, screens: [screen], fallback: screen)
        #expect(restored == CGRect(x: 0, y: 100, width: 1920, height: 800))
        #expect(screen.contains(restored))
    }

    @Test func aRemovedDisplayFitsTheFallbackOnce() {
        let saved = CGRect(x: 4000, y: 3000, width: 1920, height: 1080)
        let restored = WindowPlacing.fitting(saved, screens: [laptop.visible], fallback: laptop.visible)
        #expect(restored == laptop.visible)
        #expect(WindowPlacing.fitting(restored, screens: [laptop.visible], fallback: laptop.visible) == restored)
        #expect(WindowPlacing.fitting(saved, screens: [], fallback: nil) == saved)
    }

    @Test func fromAWindowFillingTheScreenAboveItOpensThereAStepIn() {
        let frame = WindowPlacing.frame(from: top.visible, screens: screens, fallback: laptop.frame, open: 1, size: size)
        #expect(frame == CGRect(x: -276 + 34, y: 982 + 1050 - 28 - 730, width: 1080, height: 730))
        #expect(top.visible.contains(frame))
    }

    @Test func aStepRightAndDownFromTheWindowItCameFrom() {
        let source = CGRect(x: 200, y: 150, width: 900, height: 700)
        let frame = WindowPlacing.frame(from: source, screens: screens, fallback: laptop.frame, open: 1, size: size)
        #expect(frame.minX == source.minX + 34)
        #expect(frame.maxY == source.maxY - 28)
        #expect(frame.size == size)
    }

    @Test func theScreenIsTheOneMostOfTheWindowIsOn() {
        // Mostly on the top screen, its foot over the laptop's.
        let source = CGRect(x: 100, y: 900, width: 1000, height: 800)
        let frame = WindowPlacing.frame(from: source, screens: screens, fallback: laptop.frame, open: 1, size: size)
        #expect(top.visible.contains(frame))
    }

    @Test func pastTheScreensRoomItStartsAgainFromItsTopLeft() {
        // Low on the laptop's screen: a step down leaves no room below.
        let source = CGRect(x: 300, y: 0, width: 1080, height: 600)
        let frame = WindowPlacing.frame(from: source, screens: screens, fallback: laptop.frame, open: 1, size: size)
        #expect(frame == CGRect(x: 34, y: 949 - 28 - 730, width: 1080, height: 730))
    }

    @Test func aSpotAWindowStandsOnIsSteppedPast() {
        let source = CGRect(x: 200, y: 150, width: 900, height: 700)
        // One new window already a step from it: the next a step further.
        let first = CGPoint(x: 234, y: 822)
        let frame = WindowPlacing.frame(from: source, screens: screens, fallback: laptop.frame, taken: [first], open: 2, size: size)
        #expect(frame.minX == 268 && frame.maxY == 794)
    }

    @Test func onAScreenSmallerThanANewWindowItTakesTheRoom() {
        let small = (frame: CGRect(x: 0, y: 0, width: 1000, height: 700), visible: CGRect(x: 0, y: 0, width: 1000, height: 675))
        let frame = WindowPlacing.frame(from: small.visible, screens: [small], fallback: small.frame, open: 1, size: size)
        #expect(frame == small.visible)
    }

    @Test func withNoWindowToGoByItOpensWhereItAlwaysDid() {
        let frame = WindowPlacing.frame(from: nil, screens: screens, fallback: laptop.frame, open: 2, size: size)
        #expect(frame == CGRect(x: 180 + 68, y: 110 + 56, width: 1080, height: 730))
    }
}
