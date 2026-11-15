import Foundation
import Testing
@testable import Fast

/// The production response parser, with inert JSON only. No browser or model.
@MainActor
struct TidyAnswerRangeTests {
    @Test func defaultOriginRejectsStringIntMinWithoutTrapping() {
        let said = #"{"groups":[{"name":"News","tabs":["-9223372036854775808",1,2]}]}"#
        #expect(TidyTabs.answer(said, count: 2) == [.init(name: "News", tabs: [0, 1])])
    }

    @Test func numericExtremesDoNotDiscardValidNeighbors() {
        let said = "{\"groups\":[{\"name\":\"News\",\"tabs\":[\(Int.min),1,\(Int.max),2]}]}"
        #expect(TidyTabs.answer(said, count: 2) == [.init(name: "News", tabs: [0, 1])])
    }

    @Test func invalidOnlyDoesNotCreateAGroup() {
        let said = #"{"groups":[{"name":"News","tabs":["-9223372036854775808",-1,0,"9223372036854775807","word",null]}]}"#
        #expect(TidyTabs.answer(said, count: 2) == nil)
    }

    @Test func zeroOriginRetainsItsExistingNumbering() {
        let said = #"{"groups":[{"name":"News","tabs":["-9223372036854775808",0,1,"9223372036854775807"]}]}"#
        #expect(TidyTabs.answer(said, count: 2, from: 0) == [.init(name: "News", tabs: [0, 1])])
    }

    @Test func extremeLowerOriginKeepsRepresentableDifferences() {
        let said = "{\"groups\":[{\"name\":\"News\",\"tabs\":[\"\(Int.min)\",\"\(Int.min + 1)\",0,\"\(Int.max)\"]}]}"
        #expect(TidyTabs.answer(said, count: 2, from: .min) == [.init(name: "News", tabs: [0, 1])])
    }

    @Test func extremeUpperOriginRejectsOverflowAndSingleTab() {
        let said = "{\"groups\":[{\"name\":\"News\",\"tabs\":[\"\(Int.max)\",\"\(Int.min)\",-1]}]}"
        #expect(TidyTabs.answer(said, count: 2, from: .max) == nil)
    }

    @Test func ordinaryNamesDuplicatesAndBoundsKeepTheirMeaning() {
        let said = #"Before {"groups":[{"name":" News. ","tabs":[1,1,2,0,9]},{"name":"Music","tabs":[2,"3",4]},{"name":"Solo","tabs":[5]},{"name":"folder vague","tabs":[5,6]}]} After"#
        #expect(TidyTabs.answer(said, count: 6) == [
            .init(name: "News", tabs: [0, 1]), .init(name: "Music", tabs: [2, 3])
        ])
    }

    @Test(arguments: [0, -1])
    func nonpositiveCountCannotCreateGroups(count: Int) {
        #expect(TidyTabs.answer(#"{"groups":[{"name":"News","tabs":[1,2]}]}"#, count: count) == nil)
    }
}
