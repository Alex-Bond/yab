import XCTest
import SwiftUI
import YabDesign
@testable import Fast

/// The column's words on a site's color (Tone.columnInk, feedback #186): a
/// gray of the site's light, in the site's own light or dark, the same for
/// sites of about the same light, so a switch between them draws nothing
/// in the column again; what is painted in the ground's color still takes
/// the site's (GroundFill).
@MainActor
final class ColumnInkTests: XCTestCase {
    private let sites = ["c0392b", "1e8449", "2471a3", "7d3c98", "d68910", "17202a", "f4d03f", "117a65", "0d1117", "5e6ad2"]

    func testTheInkKeepsTheSiteLightOrDark() {
        for hex in sites {
            let site = Tone(NSColor(hex: hex)!, lifted: true)
            let ink = Tone.columnInk(site)!
            XCTAssertTrue(ink.ink, hex)
            XCTAssertEqual(ink.scheme, site.scheme, hex)
            XCTAssertLessThan(ink.page.oklch.1, 0.01, "\(hex) is a gray")
        }
    }

    func testSitesOfTheSameLightShareOneInk() {
        let red = Tone.columnInk(Tone(NSColor(hex: "c0392b")!, lifted: true))
        let green = Tone.columnInk(Tone(NSColor(hex: "1e8449")!, lifted: true))
        let blue = Tone.columnInk(Tone(NSColor(hex: "2471a3")!, lifted: true))
        XCTAssertEqual(red, green)
        XCTAssertEqual(green, blue)
        XCTAssertNotEqual(red, Tone.columnInk(Tone(NSColor(hex: "17202a")!, lifted: true)))
    }

    func testWhatItCantStandForIsLeftAsItIs() {
        XCTAssertNil(Tone.columnInk(nil))
        let glass = Tone(NSColor(hex: "2471a3")!, lifted: true, glass: true)
        XCTAssertEqual(Tone.columnInk(glass), glass)
        let white = Tone(.white, lifted: true)
        XCTAssertEqual(Tone.columnInk(white), white)
    }

    func testTheGroundUnderGrayWordsIsTheSites() {
        let site = NSColor(hex: "7d3c98")!
        let ink = Tone.columnInk(Tone(site, lifted: true))
        let browser = Browser()
        // No tab in front: the gray's own, nothing better to go by.
        XCTAssertEqual(NSColor(GroundFill<Rectangle>.ground(ink, browser: browser)).hex, ink?.page.hex)
        // A plain tone keeps its own color.
        let plain = Tone(site, lifted: true)
        XCTAssertEqual(NSColor(GroundFill<Rectangle>.ground(plain, browser: browser)).hex, site.hex)
    }
}
