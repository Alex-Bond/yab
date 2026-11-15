import XCTest
@testable import YabPhone

/// Reader's themes on the iPhone: kept as the Mac keeps them, and sent to
/// the page as plain values.
@MainActor
final class ReaderStyleTests: XCTestCase {
    func testAThemeAndItsEditsAreKept() {
        let name = "reader-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let style = ReaderStyle(defaults: defaults)
        XCTAssertEqual(style.prefs.theme, .original)
        style.prefs.theme = .paper
        style.prefs.mode = .dark
        style.prefs.step(2)
        style.prefs.change { $0.margins = 10 }
        let again = ReaderStyle(defaults: defaults)
        XCTAssertEqual(again.prefs, style.prefs)
        XCTAssertTrue(again.prefs.edited(.paper))
        XCTAssertFalse(again.prefs.edited(.original))
        again.prefs.reset()
        XCTAssertFalse(again.prefs.edited(.paper))
    }

    func testThePageIsSentTheThemesValues() throws {
        var prefs = ReaderPrefs()
        prefs.theme = .calm
        prefs.change { $0.margins = -12 }
        let arguments = PageReader.arguments(prefs)
        XCTAssertEqual(arguments["margins"] as? Int, -12)
        let look = try XCTUnwrap(arguments["look"] as? [String: Any])
        XCTAssertEqual(look["mode"] as? String, "auto")
        XCTAssertEqual(look["size"] as? Int, ReaderThemeSpec.all[.calm]!.look.points)
        let day = try XCTUnwrap(look["day"] as? [String: Any])
        XCTAssertEqual(day["bg"] as? String, "#efe4cf")
        XCTAssertTrue((look["font"] as? String)?.contains("Iowan") == true)
    }
}
