import UIKit
import XCTest

/// Change Appearance with the actual controls, then use the returned browser.
/// Pixel receipts cover the system keyboard as well as SwiftUI.
final class AppearanceTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDarkChoiceReachesTheKeyboardAndLightRestoresThePage() {
        let app = XCUIApplication()
        XCTAssertTrue(Atlas.launch(app, state: "settings.page-appearance", ready: Atlas.readyFolder()))
        let screen = app.windows.firstMatch.frame
        let dark = app.buttons["settings.choice.appearance.dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        XCTAssertTrue(dark.isSelected)
        XCTAssertTrue(TransitionCatalog.wait { brightness(app, at: CGPoint(x: 6, y: 190)) < 0.2 }, "the actual Settings page becomes dark")
        save(app, "appearance-dark-settings")

        app.buttons["settings.back"].tap()
        app.buttons["settings.close"].tap()

        let plate = element(app, "chrome.plate")
        XCTAssertTrue(plate.waitForExistence(timeout: 5))
        plate.tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        let keyGround = CGPoint(x: screen.minX + 3, y: keyboard.frame.minY + 80)
        XCTAssertLessThan(brightness(app, at: keyGround), 0.4, "the real keyboard matches Dark")
        save(app, "appearance-dark-field-keyboard")
        input.typeText("settings")
        app.buttons["field.best"].tap()
        XCTAssertTrue(element(app, "settings.sheet").waitForExistence(timeout: 5))
        let appearance = app.buttons["settings.row.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        XCTAssertTrue(appearance.label.contains("Dark"))
        appearance.tap()
        let light = app.buttons["settings.choice.appearance.light"]
        XCTAssertTrue(light.waitForExistence(timeout: 5))
        light.tap()
        XCTAssertTrue(light.isSelected)
        XCTAssertFalse(dark.isSelected)
        XCTAssertTrue(TransitionCatalog.wait { brightness(app, at: CGPoint(x: 6, y: 190)) > 0.8 }, "Light restores the actual page immediately")
        save(app, "appearance-restored-light-settings")
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    /// Sample real pixels away from labels, glyphs and controls.
    private func brightness(_ app: XCUIApplication, at point: CGPoint) -> Double {
        let screen = app.windows.firstMatch.frame
        guard let image = app.screenshot().image.cgImage else { XCTFail("no native screenshot pixels"); return -1 }
        let x = floor((point.x - screen.minX) * CGFloat(image.width) / screen.width)
        let y = floor((point.y - screen.minY) * CGFloat(image.height) / screen.height)
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { XCTFail("the sampled surface is onscreen"); return -1 }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.prefix(3).reduce(0) { $0 + Double($1) } / (3 * 255)
    }
}
