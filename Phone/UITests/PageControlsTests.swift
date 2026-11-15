import CoreGraphics
import Network
import UIKit
import XCTest

/// Real page controls over an owned loopback article, never a personal account.
final class PageControlsTests: XCTestCase {
    private var site: PageControlsSite!
    private var folder: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = URL(fileURLWithPath: "/tmp/yab-page-controls-\(UUID().uuidString)")
        site = try PageControlsSite()
        let ready = expectation(description: "page controls site ready")
        site.ready = { ready.fulfill() }
        site.start()
        wait(for: [ready], timeout: 10)
    }

    override func tearDownWithError() throws {
        app?.terminate()
        site?.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    func testMainPlusHoldOffersPrivateTabWithoutBorrowingPublicDraftOrChangingHistory() throws {
        let original = site.url("chrome-feedback")
        launch(original, allowExistingWelcome: true, privateAuthentication: "off")
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try navigation(id)
        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText("ordinary menu draft")
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        holdPlus()
        app.buttons["chrome.menu.newprivate"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(element("field.eyes").value as? String, "on")
        XCTAssertTrue(empty(input), "a Private menu choice must not show the ordinary draft")
        XCTAssertFalse(element("newtab.card.frame").exists, "no public recent/frequent card may project into Private")
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(try navigation(id), before)
        record("Main plus native menu clean private input")
        input.typeText("private unsaved words")
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(input.value as? String, "ordinary menu draft")
        XCTAssertEqual(element("field.eyes").value as? String, "off")
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        app.webViews.buttons["Page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(savedTab()?["url"] as? String, original.absoluteString)
        XCTAssertEqual(try navigation(id), before)
        record("Main plus cancel retains real public page and draft")
    }

    func testPrivateMenuCreatesIsolatedRealPageAndOrdinaryPlusKeepsPrivateOwner() throws {
        launch(site.url("chrome-feedback"), allowExistingWelcome: true, privateAuthentication: "off")
        let publicID = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try navigation(publicID)
        holdPlus()
        app.buttons["chrome.menu.newprivate"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(element("field.eyes").value as? String, "on")
        let secret = site.url("private-chrome-feedback")
        input.typeText(secret.absoluteString)
        XCTAssertEqual(input.value as? String, secret.absoluteString)
        go().tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(app.webViews.staticTexts["Private storage clean"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        holdPlus()
        app.buttons["chrome.menu.newtab"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(element("field.eyes").value as? String, "on")
        XCTAssertTrue(empty(input))
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        app.webViews.buttons["Page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(try navigation(publicID), before)
        XCTAssertFalse(strings(in: try profile()).contains(secret.absoluteString))
        record("Private native plus menu returns real isolated page")
    }

    func testRepeatedBottomFlingsOnShortPageKeepChromeAndPageResponsive() {
        launch(site.url("fold-edge"), allowExistingWelcome: true)
        let page = app.webViews.firstMatch, plate = element("chrome.plate")
        for _ in 0..<4 { page.swipeUp(velocity: .fast) }
        XCTAssertTrue(wait { plate.value as? String == "folded" })
        record("Short page at bottom with folded chrome")
        let state = plate.value as? String
        for _ in 0..<8 {
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2))
            XCTAssertEqual(plate.value as? String, state, "The bottom edge must settle without new finger movement")
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked"].waitForExistence(timeout: 5))
        page.swipeDown(velocity: .slow)
        XCTAssertTrue(wait { plate.value as? String == "open" })
        XCTAssertTrue(app.buttons["chrome.plus"].isHittable)
        record("Short page responds and upward swipe unfolds chrome")
    }

    func testScrollFadesFullSideControlsAndReleasesTheirRealPageTouchRegions() throws {
        launch(site.url("chrome-feedback"), allowExistingWelcome: true)
        let plus = app.buttons["chrome.plus"], back = app.buttons["chrome.back"]
        app.webViews.links["Next chrome page"].tap()
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.url("chrome-feedback").absoluteString + "?doc=2" && back.isEnabled })
        let openPlus = plus.frame, openBack = back.frame
        XCTAssertEqual(openPlus.width, 48, accuracy: 1)
        XCTAssertEqual(openPlus.height, 48, accuracy: 1)
        let page = app.webViews.firstMatch, plate = element("chrome.plate")
        page.swipeUp(velocity: .slow)
        XCTAssertTrue(wait { plate.value as? String == "folded" && !plus.exists && !back.exists })
        XCTAssertEqual(plate.frame.height, 44, accuracy: 1)
        record("Folded drawn capsule and absent full size side buttons")
        let window = app.windows.firstMatch
        for (label, oldFrame, count) in [("Bottom page action", openPlus, 1), ("Bottom left page action", openBack, 2)] {
            let bottom = page.buttons[label]
            XCTAssertTrue(wait { bottom.isHittable && bottom.frame.intersects(oldFrame) })
            let overlap = bottom.frame.intersection(oldFrame)
            XCTAssertGreaterThan(overlap.height, 5)
            let point = CGPoint(x: overlap.midX, y: overlap.midY)
            XCTAssertTrue(oldFrame.contains(point))
            XCTAssertTrue(bottom.frame.contains(point), "touch must reach the real page in the former side-control region")
            window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)).tap()
            XCTAssertTrue(page.staticTexts["Bottom page touch \(count)"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.textFields["field.input"].exists)
            XCTAssertFalse(plus.exists)
            XCTAssertFalse(back.exists, "the vanished controls must not intercept or navigate the page")
        }
        page.swipeDown(velocity: .slow)
        XCTAssertTrue(wait { plate.value as? String == "open" && plus.exists })
        XCTAssertEqual(plus.frame.width, 48, accuracy: 1)
        XCTAssertEqual(plus.frame.height, 48, accuracy: 1)
        plus.tap()
        XCTAssertTrue(app.textFields["field.input"].waitForExistence(timeout: 5))
        record("Unfold restores actual full size Plus touch target")
    }

    func testRealHorizontalFingerFromPlusAndBackSwitchesTabsWhileVerticalAndNativeTapHoldRemainOwned() throws {
        let firstURL = site.url("chrome-feedback")
        launch(firstURL, allowExistingWelcome: true)
        let firstID = try XCTUnwrap(savedTab()?["id"] as? String)
        let page = app.webViews.firstMatch
        page.links["Next chrome page"].tap()
        let firstDocument = firstURL.absoluteString + "?doc=2"
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == firstDocument && self.app.buttons["chrome.back"].isEnabled })
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        let firstHistory = try navigation(firstID)

        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.typeText(site.url("article").absoluteString)
        XCTAssertEqual(input.value as? String, site.url("article").absoluteString)
        go().tap()
        XCTAssertTrue(wait { !input.exists && self.savedTab()?["url"] as? String == self.site.url("article").absoluteString })
        XCTAssertTrue(page.links["Next page"].waitForExistence(timeout: 15))
        let secondID = try XCTUnwrap(savedTab()?["id"] as? String)
        XCTAssertNotEqual(firstID, secondID)
        page.links["Next page"].tap()
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString && self.app.buttons["chrome.back"].isEnabled })
        let secondHistory = try navigation(secondID)

        swipeBottom(app.buttons["chrome.plus"], by: CGVector(dx: -240, dy: 0))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == firstID && self.savedTab()?["url"] as? String == firstDocument })
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(firstID), firstHistory)
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 2"].waitForExistence(timeout: 5))
        record("Actual horizontal finger starts on retained Plus and returns first document")

        swipeBottom(app.buttons["chrome.back"], by: CGVector(dx: 240, dy: 0))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == secondID && self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 5))
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(firstID), firstHistory); XCTAssertEqual(try navigation(secondID), secondHistory)
        swipeBottom(app.buttons["chrome.back"], by: CGVector(dx: 0, dy: -180))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == secondID && self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(secondID), secondHistory)
        // Up from the right button, the tab stack with two tabs open: the tab
        // used before comes in front, and up again the one left, each with its
        // own history, never the field or the spaces.
        swipeBottom(app.buttons["chrome.plus"], by: CGVector(dx: 0, dy: -180))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == firstID && self.savedTab()?["url"] as? String == firstDocument })
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(firstID), firstHistory)
        swipeBottom(app.buttons["chrome.plus"], by: CGVector(dx: 0, dy: -180))
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == secondID && self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(secondID), secondHistory)
        swipeBottom(app.buttons["chrome.plus"], by: CGVector(dx: -35, dy: 0), slowly: true)
        XCTAssertTrue(wait { self.savedTab()?["id"] as? String == secondID && self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        XCTAssertEqual(try navigation(secondID), secondHistory)
        app.openNewTabFromChrome()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        holdPlus()
        outside().tap()
        XCTAssertTrue(wait { !self.app.buttons["chrome.menu.newtab"].exists && self.app.buttons["chrome.plus"].isHittable })
        XCTAssertFalse(input.exists)
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["Page controls article"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.url("article").absoluteString })
        XCTAssertEqual(Array(try navigation(secondID).dropLast()), Array(secondHistory.dropLast()))
        XCTAssertEqual(try navigation(firstID), firstHistory)
        record("Ordinary Back and Plus taps and native Plus hold survive full-width swipes")
    }

    func testRealPrivateSideSwipesKeepBothDocumentsInTheirOwnJarWithoutPublishingTheirURLs() throws {
        launch(site.url("chrome-feedback"), allowExistingWelcome: true, privateAuthentication: "off")
        let publicID = try XCTUnwrap(savedTab()?["id"] as? String)
        let publicHistory = try navigation(publicID)
        let page = app.webViews.firstMatch
        let input = app.textFields["field.input"]
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let eyes = element("field.eyes")
        if eyes.value as? String != "on" { eyes.tap() }
        XCTAssertEqual(eyes.value as? String, "on")
        let firstPrivateURL = site.url("private-chrome-feedback")
        input.typeText(firstPrivateURL.absoluteString)
        XCTAssertEqual(input.value as? String, firstPrivateURL.absoluteString)
        go().tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(page.staticTexts["Private storage clean"].waitForExistence(timeout: 15))
        page.links["Next chrome page"].tap()
        XCTAssertTrue(page.buttons["Page action"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.app.buttons["chrome.back"].isEnabled })
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))

        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(eyes.value as? String, "on")
        let secondPrivateURL = site.url("private-article")
        input.typeText(secondPrivateURL.absoluteString)
        XCTAssertEqual(input.value as? String, secondPrivateURL.absoluteString)
        go().tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(page.links["Next page"].waitForExistence(timeout: 15))
        page.links["Next page"].tap()
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 15))
        XCTAssertTrue(wait { self.app.buttons["chrome.plus"].value as? String == "Private" && self.app.buttons["chrome.back"].isEnabled })
        swipeBottom(app.buttons["chrome.plus"], by: CGVector(dx: -240, dy: 0))
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 2"].waitForExistence(timeout: 5))
        swipeBottom(app.buttons["chrome.back"], by: CGVector(dx: 240, dy: 0))
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        XCTAssertFalse(input.exists); XCTAssertFalse(element("newtab.spaces").exists)
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page touch worked"].waitForExistence(timeout: 5))
        app.openNewTabFromChrome()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(eyes.value as? String, "on")
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertEqual(savedTab()?["id"] as? String, publicID)
        XCTAssertEqual(try navigation(publicID), publicHistory)
        XCTAssertFalse(strings(in: try profile()).contains(firstPrivateURL.absoluteString))
        XCTAssertFalse(strings(in: try profile()).contains(secondPrivateURL.absoluteString))
        record("Actual Private Back and Plus swipes retain isolated page listeners and public history")
    }

    private func swipeBottom(_ control: XCUIElement, by delta: CGVector, slowly: Bool = false) {
        XCTAssertTrue(wait { control.isHittable && control.frame.width >= 44 && control.frame.height >= 44 })
        let window = app.windows.firstMatch
        let frame = control.frame
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let end = CGPoint(x: point.x + delta.dx, y: point.y + delta.dy)
        XCTAssertTrue(frame.contains(point)); XCTAssertTrue(window.frame.contains(point)); XCTAssertTrue(window.frame.contains(end))
        let start = window.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(delta), withVelocity: slowly ? .slow : .fast, thenHoldForDuration: 0.05)
    }

    private func holdPlus() {
        let plus = app.buttons["chrome.plus"]
        XCTAssertTrue(wait { plus.isHittable && abs(plus.frame.height - 48) < 1 })
        // With other tabs open it is the tab stack, its menu ending in All Tabs.
        let stacked = plus.label.hasPrefix("Previous tab")
        plus.press(forDuration: 0.6)
        for id in ["newtab", "newprivate", stacked ? "alltabs" : "newchat"] {
            XCTAssertTrue(app.buttons["chrome.menu.\(id)"].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(app.textFields["field.input"].exists, "a hold must not perform the ordinary tap")
        record("Main plus actual native context menu")
    }

    private func empty(_ input: XCUIElement) -> Bool {
        let value = input.value as? String
        return value == nil || value == "" || value == input.placeholderValue
    }

    /// Themes & Settings from the page menu, as Books has it: a theme and
    /// Dark picked on the card, then Customize, recolor and reset the
    /// article being read at once.
    func testReaderThemesCardRecolorsTheArticleBeingRead() throws {
        launch(site.url("article"))
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(wait { menu.value as? String == "Reader available" })
        tapMenu()
        app.buttons["plate.menu.reader"].tap()
        XCTAssertTrue(wait { menu.value as? String == "Reader on" })
        let page = app.webViews.firstMatch
        // The article's side margin, clear of its words, above the card.
        let ground = { CGPoint(x: page.frame.minX + 6, y: page.frame.minY + page.frame.height * 0.3) }
        XCTAssertTrue(wait { self.pixel(at: ground()).brightness > 0.9 }, "Original in the light: a white page")
        record("reader original")
        tapMenu()
        let look = app.buttons["plate.menu.readerLook"]
        XCTAssertTrue(look.waitForExistence(timeout: 3))
        XCTAssertTrue(look.label.contains("Themes & Settings"))
        look.tap()
        XCTAssertTrue(element("reader.card").waitForExistence(timeout: 5))
        record("reader themes card")
        let calm = app.buttons["reader.card.theme.calm"]
        calm.tap()
        XCTAssertTrue(wait { calm.isSelected })
        app.buttons["reader.card.larger"].tap()
        app.buttons["reader.card.appearance"].tap()
        let dark = app.buttons["Dark"]
        XCTAssertTrue(dark.waitForExistence(timeout: 5))
        dark.tap()
        // Calm in the dark is #3a332b, behind the card already.
        XCTAssertTrue(wait { let c = self.pixel(at: ground()); return c.brightness < 0.3 && c.red > c.blue },
                      "the article being read took Calm's dark ground")
        record("reader themes card calm dark")
        app.buttons["reader.card.customize"].tap()
        XCTAssertTrue(element("reader.customize").waitForExistence(timeout: 5))
        app.switches["reader.customize.bold"].tap()
        record("reader customize theme")
        app.buttons["reader.customize.font"].tap()
        XCTAssertTrue(app.buttons["reader.fonts.georgia"].waitForExistence(timeout: 5))
        app.buttons["reader.fonts.georgia"].tap()
        record("reader customize fonts")
        app.buttons["reader.fonts.back"].tap()
        app.buttons["reader.customize.done"].tap()
        XCTAssertTrue(element("reader.card").waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reader.card.theme.calm"].label.contains("edited"))
        app.buttons["reader.card.close"].tap()
        XCTAssertTrue(wait { !self.element("reader.card").exists })
        record("reader calm dark edited")
        XCTAssertEqual(menu.value as? String, "Reader on")
    }

    func testPillBecomesPageMenuAndRestoresReaderReloadBackSpacesAndPlus() throws {
        let article = site.url("article")
        launch(article)
        let page = app.webViews.firstMatch
        let menu = app.buttons["chrome.pageMenu"]
        let plate = element("chrome.plate")
        XCTAssertTrue(wait { menu.value as? String == "Reader available" })
        XCTAssertEqual(app.buttons["chrome.plus"].label, "New Tab")
        XCTAssertFalse(element("chrome.space").exists)
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        record("page controls original pill")
        tapMenu()
        XCTAssertTrue(app.buttons["plate.menu.reload"].waitForExistence(timeout: 3))
        XCTAssertFalse(plate.exists, "the source address pill must leave the hierarchy while its menu is expanded")
        XCTAssertFalse(app.buttons["chrome.plus"].exists)
        XCTAssertGreaterThan(element("plate.menu").frame.width, app.windows.firstMatch.frame.width * 0.8)
        record("page controls expanded native menu")
        outside().tap()
        XCTAssertTrue(wait { !self.element("plate.menu").exists && plate.exists })
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        tapMenu()
        let reader = app.buttons["plate.menu.reader"]
        XCTAssertTrue(reader.waitForExistence(timeout: 3))
        XCTAssertTrue(reader.isEnabled)
        reader.tap()
        XCTAssertTrue(wait { menu.value as? String == "Reader on" })
        XCTAssertFalse(page.buttons["Page action"].exists)
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, article.absoluteString)
        tapMenu()
        XCTAssertTrue(reader.waitForExistence(timeout: 3))
        XCTAssertEqual(reader.label, "Exit Reader")
        reader.tap()
        XCTAssertTrue(page.buttons["Page action"].waitForExistence(timeout: 5))
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 2"].waitForExistence(timeout: 5), "Reader exit must retain the original listener and DOM")
        page.links["Next page"].tap()
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        let before = try navigation(id)
        let reload = app.buttons["chrome.reload"]
        XCTAssertTrue(wait { reload.label == "Reload Page" && reload.isEnabled })
        site.holdNextReload()
        reload.tap()
        XCTAssertTrue(wait { self.site.reloadCount == 2 && reload.label == "Stop Loading" })
        record("page controls held reload shows Stop")
        reload.tap()
        XCTAssertTrue(wait { reload.label == "Reload Page" })
        site.releaseReload()
        reload.tap()
        XCTAssertTrue(page.staticTexts["Page control reload 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { reload.label == "Reload Page" })
        XCTAssertTrue(page.staticTexts["Page storage kept"].exists)
        XCTAssertEqual(site.reloadCount, 3)
        XCTAssertEqual(try navigation(id), before)
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        tapMenu()
        XCTAssertTrue(app.buttons["plate.menu.reader"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["plate.menu.reader"].isEnabled, "a short page cannot offer fake Reader")
        outside().tap()
        XCTAssertTrue(wait { !self.element("plate.menu").exists && plate.exists })
        app.buttons["chrome.back"].tap()
        XCTAssertTrue(page.staticTexts["Page controls article"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == article.absoluteString })
        let start = plate.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -260)), withVelocity: .fast, thenHoldForDuration: 0.05)
        XCTAssertTrue(wait { self.element("newtab.spaces").exists && !self.app.keyboards.firstMatch.exists })
        record("page controls upward swipe brings the spaces")
        app.closeField()
        XCTAssertTrue(wait { !self.element("newtab.spaces").exists && self.element("chrome.plate").exists })
        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(self.element("field.eyes").value as? String, "off")
        XCTAssertEqual(savedTab()?["id"] as? String, id, "opening New Tab does not replace the selected page")
        outside().tap()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 3"].waitForExistence(timeout: 5))
        record("page controls browser touches after plus cancellation")
    }

    func testPrivateMenuAndPlusPreservePrivacyAndPageTouches() throws {
        launch(site.url("article"), privateAuthentication: "off")
        app.buttons["chrome.plus"].tap()
        let input = app.textFields["field.input"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let eyes = element("field.eyes")
        if eyes.value as? String != "on" { eyes.tap() }
        XCTAssertEqual(eyes.value as? String, "on")
        let privateURL = site.url("private-article")
        input.typeText(privateURL.absoluteString)
        XCTAssertEqual(input.value as? String, privateURL.absoluteString)
        go().tap()
        XCTAssertTrue(wait { !input.exists })
        let page = app.webViews.firstMatch
        XCTAssertTrue(page.staticTexts["Page controls article"].waitForExistence(timeout: 15))
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(wait { menu.value as? String == "Reader available" })
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        tapMenu()
        XCTAssertTrue(app.buttons["plate.menu.reload"].waitForExistence(timeout: 3))
        for action in ["ask", "task", "onMac", "keep"] { XCTAssertFalse(app.buttons["plate.menu.\(action)"].exists) }
        XCTAssertTrue(app.buttons["plate.menu.copy"].exists)
        XCTAssertTrue(app.buttons["plate.menu.share"].exists)
        record("page controls actual private menu")
        app.buttons["plate.menu.reader"].tap()
        XCTAssertTrue(wait { menu.value as? String == "Reader on" })
        XCTAssertFalse(page.buttons["Page action"].exists)
        tapMenu()
        XCTAssertTrue(app.buttons["plate.menu.reader"].waitForExistence(timeout: 3))
        app.buttons["plate.menu.reader"].tap()
        XCTAssertTrue(page.buttons["Page action"].waitForExistence(timeout: 5))
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        app.buttons["chrome.plus"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertEqual(eyes.value as? String, "on", "New Tab within Private must keep private routing")
        let empty = input.value as? String
        XCTAssertTrue(empty == nil || empty == "" || (input.placeholderValue != nil && empty == input.placeholderValue))
        app.closeField()
        XCTAssertTrue(wait { !input.exists })
        XCTAssertTrue(page.staticTexts["Page controls article"].exists)
        XCTAssertEqual(app.buttons["chrome.plus"].value as? String, "Private")
        let profile = try profile()
        XCTAssertFalse(strings(in: profile).contains(privateURL.absoluteString), "private page controls must not write their URL into the profile")
        record("page controls private page restored after plus")
    }

    func testLargeTypePageMenuScrollsAndBackdropRestoresActualPage() {
        launch(site.url("article"), large: true)
        tapMenu()
        let panel = element("plate.menu")
        let reload = app.buttons["plate.menu.reload"]
        XCTAssertTrue(reload.waitForExistence(timeout: 3))
        let window = app.windows.firstMatch.frame
        let safeTop = window.minY + 54
        let safeBottom = window.maxY - 8 + 1
        XCTAssertTrue(wait { reload.isHittable && reload.frame.minY >= safeTop && reload.frame.maxY <= safeBottom }, "the address row must fit under the status bar")
        XCTAssertGreaterThanOrEqual(reload.frame.width, 44)
        XCTAssertGreaterThanOrEqual(reload.frame.height, 44)
        record("page controls actual largest type menu before scroll")
        let last = app.buttons["plate.menu.siteSettings"]
        XCTAssertTrue(last.exists)
        if !last.isHittable || last.frame.minY < safeTop || last.frame.maxY > safeBottom {
            let windowElement = app.windows.firstMatch
            let origin = windowElement.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: window.width * 0.5, dy: window.height * 0.75))
            let end = origin.withOffset(CGVector(dx: window.width * 0.5, dy: window.height * 0.32))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.05)
        }
        let lastFits = wait { last.isHittable && last.frame.minY >= safeTop && last.frame.maxY <= safeBottom }
        record("page controls actual largest type menu after finger scroll")
        XCTAssertTrue(lastFits, "the capped page menu must let large text reach Site Settings at its foot")
        XCTAssertGreaterThanOrEqual(last.frame.height, 44)
        let scrolledAX = XCTAttachment(string: "Menu AX frame=\(panel.frame); Site Settings frame=\(last.frame); visible bounds=\(safeTop)...\(safeBottom)")
        scrolledAX.name = "Largest Page Menu actual Site Settings"; scrolledAX.lifetime = .keepAlways; add(scrolledAX)
        record("page controls actual largest type scrolled menu")
        // Beside the sheet, under the status bar: the room it leaves to tap.
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.width * 0.5, dy: 66)).tap()
        XCTAssertTrue(wait { !panel.exists && self.element("chrome.plate").exists })
        let page = app.webViews.firstMatch
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
    }

    /// A held reload: ↻ turns into Stop while the page loads, and that says
    /// it (e761c235 took the loading line away on purpose); Stop stops it,
    /// and the page's state is the same after.
    func testHeldReloadTurnsReloadIntoStopAndKeepsRealPageState() throws {
        launch(site.url("article"))
        let page = app.webViews.firstMatch
        page.links["Next page"].tap()
        XCTAssertTrue(page.staticTexts["Page control reload 1"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == self.site.nextURL.absoluteString })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let before = try navigation(id)
        let reload = app.buttons["chrome.reload"]
        XCTAssertTrue(wait { reload.label == "Reload Page" && reload.value as? String == "ready" && reload.isEnabled })
        let idle = reload.frame
        record("held reload: the idle plate with its reload")
        site.holdNextReload()
        reload.tap()
        XCTAssertTrue(wait { self.site.reloadCount == 2 && reload.label == "Stop Loading" && reload.value as? String == "loading" },
                      "a held reload turns ↻ into Stop: \(reload.label), \(String(describing: reload.value))")
        XCTAssertEqual(reload.frame, idle, "Stop takes ↻'s place")
        XCTAssertTrue(reload.isHittable)
        record("held reload: Stop where reload was")
        XCTAssertEqual(site.reloadCount, 2)
        reload.tap()
        XCTAssertTrue(wait { reload.label == "Reload Page" })
        site.releaseReload()
        reload.tap()
        XCTAssertTrue(page.staticTexts["Page control reload 3"].waitForExistence(timeout: 10))
        XCTAssertTrue(wait { reload.label == "Reload Page" })
        XCTAssertEqual(site.reloadCount, 3)
        XCTAssertTrue(page.staticTexts["Page storage kept"].exists)
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, site.nextURL.absoluteString)
        XCTAssertEqual(try navigation(id), before)
        page.buttons["Page action"].tap()
        XCTAssertTrue(page.staticTexts["Page touch worked"].waitForExistence(timeout: 5))
        record("held reload restored real page action and storage")
    }

    /// Optional existing ready/recording/done markers let the farm film the
    /// real menu transition. Screenshots alone do not prove the animation.
    func testFilmPillToPageMenuAndBackWithDefaultMotion() throws {
        let film = Atlas.environment["YAB_FILM_PAGE_CONTROLS"] == "1" ? Atlas.out.appendingPathComponent("film", isDirectory: true) : nil
        if let film {
            try FileManager.default.createDirectory(at: film, withIntermediateDirectories: true)
            for name in ["ready", "recording", "done"] { try? FileManager.default.removeItem(at: film.appendingPathComponent(name)) }
        }
        let original = site.url("chrome-feedback")
        launch(original, allowExistingWelcome: true, contentSizeCategory: UIContentSizeCategory.large.rawValue)
        let expectedTitle = "A genuinely long page name that wraps across the native page menu header without moving its bottom edge"
        XCTAssertTrue(wait { self.savedTab()?["url"] as? String == original.absoluteString
            && self.savedTab()?["title"] as? String == expectedTitle })
        let id = try XCTUnwrap(savedTab()?["id"] as? String)
        let history = try navigation(id)
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(wait { menu.value as? String == "Reader available" })
        record("page menu film actual source pill")
        if let film {
            try Data().write(to: film.appendingPathComponent("ready"))
            XCTAssertTrue(Atlas.waitForFile(film.appendingPathComponent("recording"), timeout: 30))
        }
        let start = Date()
        tapMenu()
        let touched = Date()
        XCTAssertTrue(app.buttons["plate.menu.reload"].waitForExistence(timeout: 3))
        XCTAssertFalse(element("chrome.plate").exists)
        let expanded = Date()
        // The page menu: the plate is its address row (the host only, however long
        // the page's name), tiles, the list, Site Settings at its foot.
        let host = element("plate.menu.host"), reader = app.buttons["plate.menu.reader"]
        let site = app.buttons["plate.menu.siteSettings"]
        var geometryPassed = false
        defer {
            if !geometryPassed {
                record("Page menu strict geometry failure native screen")
                let tree = XCTAttachment(string: app.debugDescription)
                tree.name = "Page menu strict geometry failure actual AX"
                tree.lifetime = .keepAlways; add(tree)
            }
        }
        XCTAssertTrue(wait { host.exists && reader.isHittable && site.isHittable && host.frame.height > 0 })
        let window = app.windows.firstMatch.frame
        let hostFrame = host.frame, readerFrame = reader.frame, siteFrame = site.frame
        let geometry = XCTAttachment(string: "Actual host=\(hostFrame), reader=\(readerFrame), site settings=\(siteFrame), window=\(window)")
        geometry.name = "Page menu geometry"; geometry.lifetime = .keepAlways; add(geometry)
        record("Page menu strict geometry before assertions native screen")
        XCTAssertFalse(host.label.contains("genuinely long"), "the row says the host, not the page's name: \(host.label)")
        XCTAssertLessThan(hostFrame.maxY, readerFrame.minY)
        for frame in [readerFrame, siteFrame] {
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            XCTAssertTrue(window.contains(frame))
        }
        XCTAssertTrue(reader.isEnabled)
        XCTAssertEqual(siteFrame.maxY, window.maxY - 8 - 16, accuracy: 2)
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, original.absoluteString)
        XCTAssertEqual(try navigation(id), history)
        geometryPassed = true
        record("page menu film actual expanded material")
        outside().tap()
        XCTAssertTrue(wait { !self.element("plate.menu").exists && self.element("chrome.plate").exists })
        app.webViews.buttons["Page action"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Page action worked 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(savedTab()?["id"] as? String, id)
        XCTAssertEqual(savedTab()?["url"] as? String, original.absoluteString)
        XCTAssertEqual(try navigation(id), history)
        record("page menu film returned real page")
        if let film {
            try Atlas.json([
                "transition": "pageControls", "state": "real owned article", "noAnimation": false,
                "start": start.timeIntervalSince1970, "touched": touched.timeIntervalSince1970,
                "expanded": expanded.timeIntervalSince1970, "arrived": Date().timeIntervalSince1970, "ok": true,
            ]).write(to: film.appendingPathComponent("done"))
        }
    }

    private func launch(_ url: URL, large: Bool = false, allowExistingWelcome: Bool = false, privateAuthentication: String? = nil,
                        contentSizeCategory: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-YabProfileDirectory", folder.path, "-YabURL", url.absoluteString, "-YabNoAnim", "NO"]
        if let contentSizeCategory { app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory] }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if let privateAuthentication { app.launchArguments += ["-YabPrivateLockTestAuthentication", privateAuthentication] }
        app.launchEnvironment = ["YAB_TEST": "1", "YAB_HAPTICS_SILENT": "1"]
        if Atlas.environment["YAB_FILM_PAGE_CONTROLS"] == "1" {
            let film = Atlas.out.appendingPathComponent("film", isDirectory: true)
            app.launchEnvironment["YAB_FRAMEMETER"] = "1"
            app.launchEnvironment["YAB_FILM_MARK"] = film.appendingPathComponent("recording").path
            app.launchEnvironment["YAB_PERF_OUT"] = film.appendingPathComponent("frames.jsonl").path
        }
        app.terminate()
        app.launch()
        let notNow = app.buttons["welcome.start"]
        let input = app.textFields["field.input"]
        if allowExistingWelcome {
            XCTAssertTrue(wait { notNow.exists || input.exists || self.app.webViews.staticTexts["Page controls article"].exists })
            // The page draws before the welcome's tray has risen over it (it
            // comes by itself 1.3 s in): wait for the tray before going on.
            app.passWelcome(timeout: 6)
            if input.waitForExistence(timeout: 2) { app.closeField() }
            XCTAssertTrue(wait { !input.exists && !self.element("welcome").exists }, "the welcome stayed over the page")
        } else {
            XCTAssertTrue(notNow.waitForExistence(timeout: 10))
            app.passWelcome()
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            app.closeField()
            XCTAssertTrue(wait { !input.exists })
        }
        XCTAssertTrue(app.webViews.staticTexts["Page controls article"].waitForExistence(timeout: 15))
    }

    private func tapMenu() {
        let menu = app.buttons["chrome.pageMenu"]
        XCTAssertTrue(wait { menu.isHittable }, "Page Menu must own its actual finger target rather than fall back to the address button")
        let window = app.windows.firstMatch
        let plate = element("chrome.plate")
        XCTAssertTrue(wait { plate.exists && plate.frame.width >= 88 })
        let plateFrame = plate.frame
        let menuFrame = menu.frame
        // Fresh native glass can report the full pane as the Menu AX frame.
        // Deliver the finger to its drawn 44-point slot at the pane's left edge.
        let point = CGPoint(x: plateFrame.minX + 22, y: plateFrame.midY)
        let target = CGVector(dx: point.x - window.frame.minX, dy: point.y - window.frame.minY)
        let receipt = XCTAttachment(string: "Page Menu frame=\(menuFrame), plate frame=\(plateFrame), actual window target=\(target), hittable=\(menu.isHittable)")
        receipt.name = "Page Menu actual finger target"; receipt.lifetime = .keepAlways; add(receipt)
        let beforeTouch = XCTAttachment(screenshot: app.screenshot())
        beforeTouch.name = "Page Menu physical side-button before touch"; beforeTouch.lifetime = .keepAlways; add(beforeTouch)
        XCTAssertGreaterThanOrEqual(menuFrame.width, 44, "the menu must expose its actual touch target")
        XCTAssertGreaterThanOrEqual(menuFrame.height, 44, "the menu must expose its actual touch target")
        XCTAssertTrue(menuFrame.contains(point), "the physical side-button must remain within its native AX target")
        XCTAssertTrue(plateFrame.contains(point))
        window.coordinate(withNormalizedOffset: .zero).withOffset(target).tap()
        XCTAssertFalse(app.textFields["field.input"].exists, "the Page Menu finger must not open the address field")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func outside() -> XCUICoordinate {
        app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 6, dy: app.windows.firstMatch.frame.height * 0.2))
    }
    private func go() -> XCUIElement {
        app.keyboards.buttons.matching(NSPredicate(format: "label ==[c] 'go' OR identifier ==[c] 'go'")).firstMatch
    }
    private func wait(_ condition: () -> Bool) -> Bool {
        let until = Date().addingTimeInterval(10)
        while Date() < until {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
    private func pixel(at point: CGPoint) -> (red: Double, blue: Double, brightness: Double) {
        let screen = app.windows.firstMatch.frame
        guard let image = app.screenshot().image.cgImage else { return (0, 0, -1) }
        let x = floor((point.x - screen.minX) * CGFloat(image.width) / screen.width)
        let y = floor((point.y - screen.minY) * CGFloat(image.height) / screen.height)
        guard let one = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return (0, 0, -1) }
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return }
            context.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        let rgb = bytes.prefix(3).map { Double($0) / 255 }
        return (rgb[0], rgb[2], rgb.reduce(0, +) / 3)
    }
    private func record(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func profile() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("profile.json"))) as? [String: Any])
    }
    private func savedTab() -> [String: Any]? {
        guard let profile = try? profile(), let spaces = profile["spaces"] as? [[String: Any]] else { return nil }
        for space in spaces {
            guard let id = space["current"] as? String, let tabs = space["today"] as? [[String: Any]] else { continue }
            if let tab = tabs.first(where: { $0["id"] as? String == id }) { return tab }
        }
        return nil
    }
    private func navigation(_ id: String) throws -> [String] {
        let dictionary = try profile()
        let all = try XCTUnwrap(dictionary["navigation"] as? [String: Any])
        let state = try XCTUnwrap(all[id] as? [String: Any])
        let entries = try XCTUnwrap(state["entries"] as? [[String: Any]])
        let index = try XCTUnwrap(state["index"] as? Int)
        return entries.compactMap { $0["url"] as? String } + ["index=\(index)"]
    }
    private func strings(in value: Any) -> [String] {
        if let string = value as? String { return [string] }
        if let array = value as? [Any] { return array.flatMap { strings(in: $0) } }
        if let dictionary = value as? [String: Any] { return dictionary.values.flatMap { strings(in: $0) } }
        return []
    }
}

/// Shared only by these test scenarios and Safari's owned-simulator reference.
final class PageControlsSite: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "yab.page-controls-site")
    private var connections: [NWConnection] = []
    private var counts: [String: Int] = [:]
    private var holdReload = false
    private var pending: (NWConnection, Data)?
    var ready: (() -> Void)?
    var reloadCount: Int { queue.sync { counts["/next"] ?? 0 } }
    var nextURL: URL { URL(string: "next?q=a%2Bb#part", relativeTo: baseURL)!.absoluteURL }
    private var baseURL: URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/")! }

    init() throws {
        let options = NWParameters.tcp
        options.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: options)
    }
    func url(_ route: String) -> URL { baseURL.appendingPathComponent(route) }
    func start() {
        listener.stateUpdateHandler = { [weak self] state in if case .ready = state { self?.ready?() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, bytes: Data())
        }
        listener.start(queue: queue)
    }
    func stop() {
        queue.sync { pending = nil; connections.forEach { $0.cancel() }; connections.removeAll(); listener.cancel() }
    }
    func holdNextReload() { queue.sync { holdReload = true } }
    func releaseReload() {
        queue.sync {
            if let (connection, rest) = pending {
                connection.send(content: rest, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
            pending = nil
        }
    }
    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, done, error in
            guard let self else { connection.cancel(); return }
            var all = bytes
            if let chunk { all.append(chunk) }
            guard all.count <= 65_536 else { connection.cancel(); return }
            guard all.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if done || error != nil { connection.cancel() } else { self.receive(connection, bytes: all) }
                return
            }
            let target = String(decoding: all, as: UTF8.self).components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = URL(string: target, relativeTo: self.baseURL)?.path ?? "/"
            self.counts[path, default: 0] += 1
            let body = Data(self.html(path, count: self.counts[path]!).utf8)
            let header = Data("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            if path == "/next", self.holdReload {
                self.holdReload = false
                self.pending = (connection, Data(body.suffix(1)))
                connection.send(content: header + body.dropLast(), completion: .contentProcessed { _ in })
            } else {
                connection.send(content: header + body, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
    }
    private func html(_ path: String, count: Int) -> String {
        let top = "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'><title>Page controls</title><style>body{font:18px -apple-system;padding:16px;margin:0;background:#d7eeff;color:#111}button,a{display:block;padding:12px;margin:8px 0}article{padding-bottom:180px}p{line-height:1.5}</style></head><body>"
        if path == "/fold-edge" {
            return top + "<style>body{box-sizing:border-box;height:calc(100vh + 120px)}h1{font-size:20px}#action{position:fixed;top:140px;left:30px}#result{position:fixed;top:210px;left:30px}</style><h1>Page controls article</h1><button id='action' onclick=\"document.getElementById('result').textContent='Page action worked'\">Page action</button><p id='result'></p></body></html>"
        }
        if ["/chrome-feedback", "/private-chrome-feedback"].contains(path) {
            let title = "A genuinely long page name that wraps across the native page menu header without moving its bottom edge"
            let paragraphs = Array(repeating: "The owned browser page preserves its original listener and origin while native controls appear and disappear. A real downward or upward gesture changes only the chrome state; the same document remains available for touch and private storage remains isolated. ", count: 16).map { "<p>\($0)</p>" }.joined()
            let seed = path == "/chrome-feedback" ? "localStorage.setItem('chrome-owner','public');document.cookie='chrome-owner=public;path=/';" : ""
            let storage = "<p id='scope'></p><script>document.getElementById('scope').textContent=(localStorage.getItem('chrome-owner')===null&&!document.cookie.includes('chrome-owner=public'))?'Private storage clean':'Public storage present';\(seed)</script>"
            return top.replacingOccurrences(of: "<title>Page controls</title>", with: "<title>\(title)</title>")
                + "<h1>Page controls article</h1><a href='/chrome-feedback?doc=2'>Next chrome page</a>\(storage)<p id='result'></p><button onclick=\"window.actionCount=(window.actionCount||0)+1;document.getElementById('result').textContent='Page action worked '+window.actionCount\">Page action</button><article>\(paragraphs)</article>"
                + "<p id='bottom-result' style='position:fixed;top:60px;left:12px'></p><button aria-label='Bottom page action' style='position:fixed;bottom:0;right:12px;width:50px;height:44px;padding:0;margin:0;font-size:12px' onclick=\"window.bottomCount=(window.bottomCount||0)+1;document.getElementById('bottom-result').textContent='Bottom page touch '+window.bottomCount\">Touch</button><button aria-label='Bottom left page action' style='position:fixed;bottom:0;left:12px;width:50px;height:44px;padding:0;margin:0;font-size:12px' onclick=\"window.bottomCount=(window.bottomCount||0)+1;document.getElementById('bottom-result').textContent='Bottom page touch '+window.bottomCount\">Touch</button></body></html>"
        }
        if path == "/next" {
            return top + "<h1 id='part'>Page control reload \(count)</h1><p id='storage'></p><button onclick=\"document.getElementById('storage').textContent='Page touch worked'\">Page action</button><script>document.getElementById('storage').textContent=localStorage.getItem('page-controls-seed')==='kept'?'Page storage kept':'Page storage missing';</script></body></html>"
        }
        let paragraph = "The browser keeps each article inside the same real page. Reading this long document removes distractions while retaining the page's address, history, original forms and event listeners. Returning to the page restores the reader's original position without creating a new tab."
        let prose = (0..<16).map { "<p>Section \($0 + 1). \(paragraph)</p>" }.joined()
        return top + "<article><h1>Page controls article</h1><button onclick=\"window.actions=(window.actions||0)+1;document.getElementById('action').textContent='Page action worked '+window.actions\">Page action</button><p id='action'></p><a href='next?q=a%2Bb#part'>Next page</a>\(prose)</article><script>localStorage.setItem('page-controls-seed','kept');</script></body></html>"
    }
}
