@testable import Fast
import XCTest

@MainActor
final class FloatSpeedTests: XCTestCase {
    func testSaid() {
        XCTAssertEqual(Floater.said(1), "1×")
        XCTAssertEqual(Floater.said(2), "2×")
        XCTAssertEqual(Floater.said(1.5), "1.5×")
        XCTAssertEqual(Floater.said(1.25), "1.25×")
        XCTAssertEqual(Floater.said(0.75), "0.75×")
        XCTAssertEqual(Floater.said(1.0000001), "1×")
    }

    func testSteps() {
        XCTAssertEqual(Floater.speed(after: 1, way: 1), 1.25)
        XCTAssertEqual(Floater.speed(after: 1, way: -1), 0.75)
        XCTAssertEqual(Floater.speed(after: 2, way: 1), nil)
        XCTAssertEqual(Floater.speed(after: 0.5, way: -1), nil)
        // A page's own 1.1 goes to the steps either side of it.
        XCTAssertEqual(Floater.speed(after: 1.1, way: 1), 1.25)
        XCTAssertEqual(Floater.speed(after: 1.1, way: -1), 1)
    }

    func testTracksOfAPage() {
        let found = Floater.Subtitles([1, ["English", "", "Deutsch"]] as [Any])
        XCTAssertEqual(found?.tracks.map(\.name), ["English", "Track 2", "Deutsch"])
        XCTAssertEqual(found?.now, 1)
        XCTAssertEqual(found?.spoken, -1)
        // Named only: all of them, few as they are.
        XCTAssertEqual(found?.first(languages: ["ru-RU"]), [0, 1, 2])
        XCTAssertNil(Floater.Subtitles(nil))
        XCTAssertEqual(Floater.Subtitles([-1, [] as [Any]] as [Any])?.tracks.count, 0)
    }

    func testYouTubesFewFirst() {
        let rows: [Any] = [["Arabic", "ar", ""], ["English", "en", ""], ["English (auto-generated)", "en", "asr"],
                           ["German", "de", ""], ["Russian", "ru", "translated"]]
        let found = Floater.Subtitles([-1, rows, 1] as [Any])
        XCTAssertEqual(found?.tracks[4].translated, true)
        // The spoken language's first, then this Mac's languages, the
        // translation, nothing else.
        XCTAssertEqual(found?.first(languages: ["en-US", "ru-RU"]), [1, 2, 4])
        // Whatever shows now joins them.
        var showing = found
        showing?.now = 3
        XCTAssertEqual(showing?.first(languages: ["en-US"]), [1, 2, 4, 3])
        XCTAssertEqual(Floater.Subtitles.base("pt-BR"), "pt")
    }
}
