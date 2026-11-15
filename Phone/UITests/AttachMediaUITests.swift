import XCTest

/// Add to Chat: Camera, Photos and Files as three cards of one size; Photos
/// opens the system's picker, and what is picked there waits in the field as
/// image files. The simulator's library holds the photos the farm job added.
final class AttachMediaUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-YabWorld", "mira", "-YabState", state]
        app.launch()
        XCTAssertTrue(app.buttons["chat.attachTray.photos"].waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    func testCameraPhotosAndFilesAreThreeCardsOfOneSize() {
        let app = launch("attach.2")
        let camera = app.buttons["chat.attachTray.camera"]
        let photos = app.buttons["chat.attachTray.photos"]
        let files = app.buttons["chat.attachTray.files"]
        XCTAssertEqual(camera.value as? String, "Live preview")
        XCTAssertEqual(photos.label, "Photos")
        XCTAssertEqual(files.label, "Files")
        for card in [photos, files] {
            XCTAssertTrue(card.isHittable)
            XCTAssertEqual(card.frame.height, camera.frame.height, accuracy: 0.5)
            XCTAssertEqual(card.frame.width, camera.frame.width, accuracy: 0.5)
            XCTAssertEqual(card.frame.midY, camera.frame.midY, accuracy: 0.5)
        }
        XCTAssertLessThan(camera.frame.maxX, photos.frame.minX)
        XCTAssertLessThan(photos.frame.maxX, files.frame.minX)
        // No embedded picker and no second Photos button in the header.
        XCTAssertFalse(app.buttons["chat.attachTray.allPhotos"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["chat.attachTray.systemPhotos"].exists)
        keepShot("Tray, live camera", app: app)
    }

    func testPhotosOpensTheSystemPickerAndTwoPickedPhotosWaitAsImageFiles() {
        let app = launch("attach.4")
        app.buttons["chat.attachTray.photos"].tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "Photo,"))
        XCTAssertTrue(photo.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["chat.attachTray.photos"].isHittable, "the tray goes before the picker comes")
        keepShot("System picker", app: app)
        XCTAssertGreaterThanOrEqual(photo.count, 2)
        // The remote picker's cells report not hittable while they are drawn, so
        // press the middle of each cell by its frame.
        for n in 0..<2 {
            photo.element(boundBy: n).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        keepShot("Two photos picked", app: app)
        let add = app.buttons["Add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        let chips = app.descendants(matching: .any).matching(identifier: "chat.attachment")
        XCTAssertTrue(Poll.until(15) { chips.count == 2 }, app.debugDescription)
        let removes = app.buttons.matching(identifier: "chat.attachment.remove")
        XCTAssertEqual(removes.count, 2)
        for n in 0..<removes.count {
            let label = removes.element(boundBy: n).label
            XCTAssertTrue(label.hasSuffix(".jpg"), "an image file waits in the field: \(label)")
        }
        keepShot("Two photos in the field", app: app)
    }

    func testCameraOffLeavesPhotosWorkingAndCancelAttachesNothing() {
        let app = launch("attach.3")
        XCTAssertEqual(app.buttons["chat.attachTray.camera"].value as? String, "Open camera")
        let photos = app.buttons["chat.attachTray.photos"]
        XCTAssertTrue(photos.isHittable)
        photos.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(Poll.until(5) { !cancel.exists }, app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["chat.attachment"].exists)
        keepShot("Camera off", app: app)
    }

    private func keepShot(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}

private enum Poll {
    static func until(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }
}
