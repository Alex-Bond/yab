import Testing
@testable import Fast

struct SpacePlateRoutingTests {
    @Test func keysIncludeEveryIntermediateSpaceInEitherDirection() {
        #expect(SpacePlateRouting.places(home: 0, count: 4, toward: 3) == [1, 2, 3])
        #expect(SpacePlateRouting.places(home: 3, count: 4, toward: 0) == [0, 1, 2])
        #expect(SpacePlateRouting.places(home: 2, count: 4, toward: 2).isEmpty)
    }

    @Test func gesturesUseOnlyRealNeighborsAndNeverWrap() {
        #expect(SpacePlateRouting.places(home: 0, count: 3, toward: nil) == [1])
        #expect(SpacePlateRouting.places(home: 1, count: 3, toward: nil) == [0, 2])
        #expect(SpacePlateRouting.places(home: 2, count: 3, toward: nil) == [1])
    }

    @Test func invalidOrdersDoNotSelectRows() {
        #expect(SpacePlateRouting.places(home: 0, count: 0, toward: nil).isEmpty)
        #expect(SpacePlateRouting.places(home: 0, count: -1, toward: nil).isEmpty)
        #expect(SpacePlateRouting.places(home: -1, count: 3, toward: 1).isEmpty)
        #expect(SpacePlateRouting.places(home: 1, count: 3, toward: 3).isEmpty)
    }

    @Test func samePlateRoutesKeepNativeEligibility() {
        #expect(SpacePlateRouting.moves(from: true, to: [true, true]) == false)
        #expect(SpacePlateRouting.moves(from: false, to: [false]) == false)
        #expect(SpacePlateRouting.moves(from: true, to: []) == false)
    }

    @Test func eitherMixedDirectionCarriesItsPlate() {
        #expect(SpacePlateRouting.moves(from: true, to: [false]) == true)
        #expect(SpacePlateRouting.moves(from: false, to: [true]) == true)
    }

    @Test func anIntermediateDifferenceIsNotHiddenByMatchingEndpoints() {
        let plates: [Bool?] = [false, true, false]
        let indices = SpacePlateRouting.places(home: 0, count: 3, toward: 2)
        #expect(SpacePlateRouting.moves(from: false, to: indices.map { plates[$0] }) == true)
    }

    @Test func unknownSamePlateRoutesRequireSetupButKnownMixedWins() {
        #expect(SpacePlateRouting.moves(from: false, to: [false, nil]) == nil)
        #expect(SpacePlateRouting.moves(from: true, to: [nil]) == nil)
        #expect(SpacePlateRouting.moves(from: false, to: [nil, true]) == true)
    }

    @Test func anotherMixedGestureNeighborDoesNotChangeTheDirectKeyRoute() {
        let plates: [Bool?] = [true, false, false]
        let key = SpacePlateRouting.places(home: 1, count: 3, toward: 2)
        let swipe = SpacePlateRouting.places(home: 1, count: 3, toward: nil)
        #expect(SpacePlateRouting.moves(from: false, to: key.map { plates[$0] }) == false)
        #expect(SpacePlateRouting.moves(from: false, to: swipe.map { plates[$0] }) == true)
    }

    @Test func extensionRowHeightAndOrderCarryThePlateAcrossEveryIntermediate() {
        let four = SpacePlateRouting.Plate(shown: true, extensionHeight: 36, extensions: ["a", "b", "c", "d"])
        let eight = SpacePlateRouting.Plate(shown: true, extensionHeight: 72, extensions: ["a", "b", "c", "d", "e", "f", "g", "h"])
        let blank = SpacePlateRouting.Plate(shown: true)
        #expect(SpacePlateRouting.moves(from: four, to: [four, eight]) == true)
        #expect(SpacePlateRouting.moves(from: eight, to: [four]) == true)
        #expect(SpacePlateRouting.moves(from: four, to: [blank, four]) == true)
        #expect(SpacePlateRouting.moves(from: four, to: [four, four]) == false)
    }

    @Test func equalHeightDifferentExtensionsStillCarryThePlate() {
        let first = SpacePlateRouting.Plate(shown: true, extensionHeight: 36, extensions: ["a", "b", "c", "d"])
        let other = SpacePlateRouting.Plate(shown: true, extensionHeight: 36, extensions: ["w", "x", "y", "z"])
        #expect(SpacePlateRouting.moves(from: first, to: [other]) == true)
        #expect(SpacePlateRouting.moves(from: first, to: [nil, other]) == true)
        #expect(SpacePlateRouting.moves(from: first, to: [nil, first]) == nil)
        #expect(SpacePlateRouting.moves(from: first, to: [first]) == false)
    }
}
