import Foundation
import Testing
@testable import Fast

// The foot's row of spaces: emoji, or dots once there are too many for the
// room, as Arc's; the Update button standing where the plus does never
// turns emoji to dots by itself.
struct SpaceRowPlanTests {
    @Test func narrowRoomTurnsToDots() {
        #expect(SpaceRowPlan(room: 110, count: 5).icons)
        #expect(!SpaceRowPlan(room: 110, count: 6).icons)
    }

    @Test func updateButtonLendsItsRoom() {
        // A 189 pt column with Personal and Mail: "What's new ↗" leaves
        // about 40 pt where the plus left about 100.
        let plan = SpaceRowPlan(room: 40, count: 2, lent: 62)
        #expect(plan.icons)
        #expect(plan.pitch == 20)
        #expect(!SpaceRowPlan(room: 40, count: 2).icons)
    }

    @Test func tooTightGivesWayAllTheSame() {
        #expect(!SpaceRowPlan(room: 24, count: 2, lent: 200).icons)
    }

    @Test func automaticDotsReserveAnIconSlot() {
        let plan = SpaceRowPlan(room: 160, count: 12)
        #expect(!plan.icons)
        #expect(plan.activeIcon)
        #expect(plan.width(on: true) == 22)
        #expect(abs(plan.width(on: false) * 11 + plan.width(on: true) - 160) < 0.001)
        #expect(!plan.scrolls)
    }

    @Test func automaticDotsScrollWhenTheIconNeedsRoom() {
        let plan = SpaceRowPlan(room: 120, count: 12)
        #expect(plan.scrolls)
        #expect(plan.width(on: true) == 22)
        #expect(plan.pitch == 10)
    }

    @Test func dotsAskedKeepEqualSlots() {
        let plan = SpaceRowPlan(room: 160, count: 12, dots: true)
        #expect(!plan.activeIcon)
        #expect(plan.width(on: true) == plan.width(on: false))
        #expect(!plan.scrolls)
    }

    @Test func fractionalPitchDoesNotTriggerScrolling() {
        #expect(!SpaceRowPlan(room: 200, count: 12).scrolls)
        #expect(!SpaceRowPlan(room: 160, count: 12, dots: true).scrolls)
    }

    @Test func dotsAskedStayDots() {
        #expect(!SpaceRowPlan(room: 200, count: 2, dots: true, lent: 62).icons)
    }
}
