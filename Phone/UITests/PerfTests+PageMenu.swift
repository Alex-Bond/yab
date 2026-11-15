import XCTest

/// The page menu out of the plate, and Site Settings in the same sheet.
extension PerfTests {
    func testPlateMenu() throws { try measure("plateMenu") }
    func testPlateMenuClose() throws { try measure("plateMenuClose") }
    func testSiteSettingsIn() throws { try measure("siteSettingsIn") }
    func testSiteSettingsOut() throws { try measure("siteSettingsOut") }
    func testDownloadsIn() throws { try measure("downloadsIn") }
    func testDownloadsOut() throws { try measure("downloadsOut") }
    func testDownloadsDeep() throws { try measure("downloadsDeep") }
    func testDownloadsFromNow() throws { try measure("downloadsFromNow") }
}
