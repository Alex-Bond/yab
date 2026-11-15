import Foundation
import Testing
@testable import Fast

// The small window's button: "Open" with one space or spaces off,
// the name of the space on screen otherwise, and its menu the space on
// screen first, the others after it in their order.
struct LinkSpacesTests {
    static let first = Space(id: Space.firstID, name: "Personal", icon: "🏠", ownSignIns: false)
    static let work = Space(id: UUID(), name: "Work", icon: "💼", ownSignIns: true)
    static let lab = Space(id: UUID(), name: "Lab", icon: "🧪", ownSignIns: false)
    static let all = [first, work, lab]

    @Test func oneSpaceSaysOpen() {
        #expect(LinkSpaces.name([Self.first], current: Space.firstID, on: true) == nil)
        #expect(!LinkSpaces.shown([Self.first], on: true))
    }

    @Test func spacesOffSaysOpen() {
        #expect(LinkSpaces.name(Self.all, current: Space.firstID, on: false) == nil)
        #expect(!LinkSpaces.shown(Self.all, on: false))
    }

    @Test func namesTheSpaceOnScreen() {
        #expect(LinkSpaces.name(Self.all, current: Self.work.id, on: true) == "Work")
        #expect(LinkSpaces.name(Self.all, current: Space.firstID, on: true) == "Personal")
    }

    @Test func menuPutsTheSpaceOnScreenFirst() {
        #expect(LinkSpaces.order(Self.all, current: Self.lab.id).map(\.name) == ["Lab", "Personal", "Work"])
        #expect(LinkSpaces.order(Self.all, current: Space.firstID).map(\.name) == ["Personal", "Work", "Lab"])
        #expect(LinkSpaces.order(Self.all, current: UUID()).map(\.name) == ["Personal", "Work", "Lab"])
    }
}

// The button's words are as wide as they are, and a long name stops at
// the cap, to end in "…" rather than draw over the keys.
struct LinkSpacesWidthTests {
    @Test func shortNameIsItsOwnWidth() {
        let plain = LinkSpaces.wordsWidth(nil)
        #expect(plain > 20 && plain < LinkSpaces.wordsWidth("Work"))
        #expect(LinkSpaces.wordsWidth("Work") < LinkSpaces.wordsWidth("Personal projects"))
    }

    @Test func longNameIsCapped() {
        #expect(LinkSpaces.wordsWidth(String(repeating: "Long space name ", count: 3)) == LinkSpaces.widest)
    }
}
