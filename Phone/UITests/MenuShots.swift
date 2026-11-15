import XCTest

/// Pictures of native menus as they stand, into the job's menus/ folder
/// (and the result bundle), so every menu's glyphs can be compared with the
/// system's own symbols beside them.
extension XCTestCase {
    func menuShot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let folder = Atlas.out.appendingPathComponent("menus", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"))
    }
}
