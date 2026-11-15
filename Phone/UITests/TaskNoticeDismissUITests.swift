import SyncKit
import XCTest

/// Supplied terminal observations, real sync and real finger input. No provider
/// execution or reporter account is represented by these disposable records.
final class TaskNoticeDismissUITests: XCTestCase {
    private var folder: URL!
    private var site: ChatWireSite!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("yab-notice-ui-\(UUID())")
        site = try ChatWireSite(chat: "a:unused-notice-chat")
        let ready = expectation(description: "owned notice sync")
        site.start { ready.fulfill() }; wait(for: [ready], timeout: 5)
        site.useMagentaPage()
        let keys = folder.appendingPathComponent("Sync-test/keys")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try site.seal.raw.write(to: keys.appendingPathComponent("key"))
        try Data("owned-phone".utf8).write(to: keys.appendingPathComponent("device"))
    }

    override func tearDownWithError() throws {
        app?.terminate(); site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func wait(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
    private func shot(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func launch() {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabSync", site.base.absoluteString,
                               "-YabURL", site.base.appendingPathComponent("owned-page").absoluteString,
                               "-YabNoAnim", "NO", "-settings.welcomed", "YES"]
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        app.launch()
        XCTAssertTrue(wait { self.site.phoneRegistered && self.element("chrome.plate").exists })
        if app.textFields["field.input"].exists { XCTAssertTrue(app.closeField()) }
        XCTAssertTrue(wait { self.app.buttons["Owned page action"].isHittable })
    }
    private func sweep(_ name: String, down: Bool = false) {
        let notice = element("chrome.now")
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(wait { notice.isHittable && notice.frame.width > 0 })
        shot(name + "-before-swipe")
        if down {
            // XCTest's default swipe fits inside the 52pt notice and can
            // become a tap at the screen's lower edge. Cross the real threshold.
            let start = notice.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 90)))
        } else { notice.swipeRight() }
        let dismissed = wait { !self.element("chrome.now").exists && !self.element("task.live.chat").exists }
        shot(name + "-after-swipe")
        XCTAssertTrue(dismissed, "terminal task notice stayed after swipe: \(name)")
    }
    private func pageStillWorks() {
        XCTAssertTrue(app.buttons["Owned page action"].isHittable)
        app.buttons["Owned page action"].tap()
        XCTAssertTrue(app.buttons["Owned page touch worked"].waitForExistence(timeout: 5))
        XCTAssertTrue(site.sends.isEmpty, "dismissing a notice must not send or retry")
        XCTAssertTrue(site.failures.isEmpty)
    }

    func testCompletedNoticeSwipesAwayAndNextNoticeCanSwipeDown() throws {
        try site.taskNotice(.done, title: "iPhone Duo Cases")
        launch()
        XCTAssertTrue(wait { self.element("chrome.now").exists && self.element("chrome.now").label.contains("Completed") })
        sweep("completed")
        try site.taskNotice(.done, title: "Next completed task")
        XCTAssertTrue(wait { self.element("chrome.now").exists && self.element("chrome.now").label.contains("Next completed task") })
        sweep("next-completed", down: true)
        pageStillWorks()
    }

    func testChatErrorNoticeSwipesAwayAndStaysAwayAfterRelaunch() throws {
        try site.taskNotice(.failed, title: "ChatGPT task", progress: "Chat server could not finish")
        launch()
        XCTAssertTrue(wait { self.element("chrome.now").exists && self.element("chrome.now").label.contains("Chat server could not finish") })
        sweep("chat-error")
        app.terminate(); launch()
        XCTAssertFalse(element("chrome.now").exists)
        shot("chat-error-dismissed-after-relaunch")
        pageStillWorks()
    }
}
