import XCTest
import SyncKit
@testable import YabPhone

/// A folder looks as it does on the Mac: its shades on the color the Mac wears,
/// its own color kept through sync, its fold on the Mac's clock.
final class FolderLookTests: XCTestCase {
    private func space(look: SpaceLook?, tint: RGB = RGB(241, 250, 255)) -> Space {
        var space = Space(id: "S", name: "S", emoji: "", tint: tint)
        space.look = look
        return space
    }

    func testAColorOfItsOwnIsDeepenedInTheDark() throws {
        let picked = RGB(0xD1, 0xF1, 0xFF)
        let ground = self.space(look: SpaceLook(color: picked))
        XCTAssertEqual(ground.folderGround(dark: false), picked)
        XCTAssertEqual(ground.folderGround(dark: true), LookColor.deepened(picked))
    }

    func testASwatchKeepsTheMacsPair() throws {
        let look = try XCTUnwrap(SpaceLook(.object(["swatch": "sky", "color": "#000000"])))
        XCTAssertEqual(space(look: look).folderGround(dark: true), RGB(0x1D, 0x30, 0x4B))
        XCTAssertEqual(space(look: look).folderGround(dark: false), RGB(0x8D, 0xB6, 0xE6))
    }

    func testAWashGivesBackItsColor() {
        let picked = RGB(100, 150, 200)
        func wash(_ c: Int) -> Int { Int((Double(c) * 0.18 + 255 * 0.82).rounded()) }
        let ground = space(look: nil, tint: RGB(wash(100), wash(150), wash(200))).folderGround(dark: false)
        XCTAssertEqual(ground.r, picked.r, accuracy: 3)
        XCTAssertEqual(ground.g, picked.g, accuracy: 3)
        XCTAssertEqual(ground.b, picked.b, accuracy: 3)
    }

    func testOnlyTheMacsColorsCount() {
        XCTAssertEqual(FolderColor.rgb("teal"), RGB(0x11, 0xAF, 0x91))
        XCTAssertNil(FolderColor.rgb("black"))
        XCTAssertNil(FolderColor.rgb(nil))
    }

    func testAFolderKeepsItsColorInTheStore() throws {
        let folder = Folder(id: "F", name: "F", items: [], color: "teal")
        let back = try JSONDecoder().decode(Folder.self, from: JSONEncoder().encode(folder))
        XCTAssertEqual(back.color, "teal")
    }

    func testOpeningTurnsBeforeTheFrontLetsDown() {
        let fold = FolderFold(from: .shut, start: Date(), opening: true)
        XCTAssertEqual(fold.pose(progress: 0), .shut)
        XCTAssertEqual(fold.pose(progress: 1), .open)
        let early = fold.pose(progress: 0.2)
        XCTAssertGreaterThan(early.turn, 0)
        XCTAssertEqual(early.flap, 0)
    }

    func testShuttingLiftsTheFrontBeforeItTurnsBack() {
        let fold = FolderFold(from: .open, start: Date(), opening: false)
        let early = fold.pose(progress: 0.3)
        XCTAssertLessThan(early.flap, 1)
        XCTAssertEqual(early.turn, 1)
        XCTAssertEqual(fold.pose(progress: 1), .shut)
    }

    func testAReversalRunsFromWhereItGotTo() {
        let midway = FolderPose(flap: 0.4, turn: 0.8)
        XCTAssertEqual(FolderFold(from: midway, start: Date(), opening: false).pose(progress: 0), midway)
        XCTAssertEqual(FolderFold(from: midway, start: Date(), opening: true).pose(progress: 1), .open)
    }
}
