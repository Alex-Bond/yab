import XCTest

/// The search sheet's morphs (Transitions+Field.swift).
extension PerfTests {
    func testSheetFirstOpen() throws { try measure("sheetFirstOpen") }
    func testSheetOpen() throws { try measure("sheetOpen") }
    func testSheetToSpaces() throws { try measure("sheetToSpaces") }
    func testSheetBack() throws { try measure("sheetBack") }
    func testSpacesPlus() throws { try measure("spacesPlus") }
}
