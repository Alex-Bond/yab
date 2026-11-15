import XCTest

extension PerfTests {
    func testTabsOpen() throws { try measure("tabsOpen") }
    func testTabsCardOpen() throws { try measure("tabsCardOpen") }
    func testTabsPreviousCardOpen() throws { try measure("tabsPreviousCardOpen") }
    func testTabsThirdCardOpen() throws { try measure("tabsThirdCardOpen") }
    func testTabsCardClose() throws { try measure("tabsCardClose") }
    func testTabsScroll() throws { try measure("tabsScroll") }
    func testTabsPinch() throws { try measure("tabsPinch") }
    func testTabsNew() throws { try measure("tabsNew") }
}
