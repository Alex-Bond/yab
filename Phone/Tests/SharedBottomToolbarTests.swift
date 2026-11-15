import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Observe the actual SwiftUI representables in an owned native window.
/// Identity and native ownership, not finger/film acceptance.
@MainActor
final class SharedBottomToolbarTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false
    private var ownedApp: AppModel?
    private var oldWelcome: Bool?

    // No welcome over the toolbar: an earlier suite's world without a Mac
    // starts the first run (FirstRun.shared) and every root after it then
    // shows its tray over the buttons until it is answered.
    override func setUp() {
        oldDisabled = Motion.disabled; Motion.disabled = true
        oldWelcome = SettingsUI.shared.welcomeForced; SettingsUI.shared.welcomeForced = false
    }
    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil; ownedApp = nil; Motion.disabled = oldDisabled
        SettingsUI.shared.welcomeForced = oldWelcome
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }
    private func controllers(_ controller: UIViewController) -> [UIViewController] {
        [controller] + controller.children.flatMap(controllers)
    }
    private func until(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// `prepare` changes the world before the root is mounted.
    private func host(size: CGSize, prepare: (AppModel) -> Void = { _ in }) async throws -> (AppModel, UIView, ToolbarLeftButton, ChromePlusControl) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(origin: .zero, size: size)
        window = owned
        let app = AppModel(world: try World.load(named: "mira"), privateLockEnabled: { false })
        ownedApp = app
        prepare(app)
        let host = UIHostingController(rootView: RootView().environment(app))
        host.safeAreaRegions = []
        owned.rootViewController = host
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        let ready = await until {
            self.views(owned).contains { $0.accessibilityIdentifier == "bottom.toolbar.owner" }
                && self.views(owned).filter { $0 is ToolbarLeftButton }.count == 1
                && self.views(owned).filter { $0 is ChromePlusControl }.count == 1
        }
        XCTAssertTrue(ready, "the real root must contain one permanent left and right control")
        let toolbar = try XCTUnwrap(views(owned).first { $0.accessibilityIdentifier == "bottom.toolbar.owner" })
        let left = try XCTUnwrap(views(owned).compactMap { $0 as? ToolbarLeftButton }.first)
        let plus = try XCTUnwrap(views(owned).compactMap { $0 as? ChromePlusControl }.first)
        return (app, toolbar, left, plus)
    }

    private func stable(_ left: ToolbarLeftButton, _ plus: ChromePlusControl, leftGlass: UIView, plusGlass: UIView,
                        expectedID: String?, name: String) async throws {
        let owned = try XCTUnwrap(window)
        let app = try XCTUnwrap(ownedApp)
        let ready = await until {
            let geometry = BottomToolbarGeometry(size: owned.bounds.size, folded: app.chrome.folded, hasNow: app.nowItem != nil)
            let frame = plus.convert(plus.bounds, to: owned)
            // Folded, the stack slides in toward the capsule, smaller about
            // its middle (Safari's fold): its middle is where it lands.
            let slide = app.chrome.folded ? Metrics.Chrome.foldSlide : 0
            return plus.accessibilityIdentifier == expectedID
                && abs(frame.midX - (geometry.plus.midX - slide)) < 0.5 && abs(frame.midY - geometry.plus.midY) < 0.5
        }
        XCTAssertTrue(ready, name)
        owned.layoutIfNeeded()
        let lefts = views(owned).compactMap { $0 as? ToolbarLeftButton }
        let rights = views(owned).compactMap { $0 as? ChromePlusControl }
        XCTAssertEqual(lefts.count, 1); XCTAssertEqual(rights.count, 1)
        XCTAssertTrue(lefts.first === left); XCTAssertTrue(rights.first === plus)
        XCTAssertTrue(left.glass === leftGlass)
        XCTAssertTrue(plus.subviews.compactMap { $0 as? UIVisualEffectView }.first === plusGlass)
        XCTAssertEqual(left.bounds.size, CGSize(width: 48, height: 48))
        XCTAssertEqual(plus.bounds.size, CGSize(width: 48, height: 48))
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        })
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testActualControlsAndNativeMaterialsOnSmallScreen() async throws {
        let (_, toolbar, left, plus) = try await host(size: CGSize(width: 375, height: 812))
        XCTAssertNil(toolbar.hitTest(CGPoint(x: 187, y: 240), with: nil), "empty native host must pass through to the actual page")
        let leftGlass = left.glass
        let plusGlass = try XCTUnwrap(plus.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        try await stable(left, plus, leftGlass: leftGlass, plusGlass: plusGlass,
                         expectedID: "chrome.plus", name: "Actual source toolbar 375 by 812")
        XCTAssertEqual(left.accessibilityIdentifier, "chrome.back")
    }

    func testFoldingKeepsTheSameControlsAndRestoresThem() async throws {
        let (app, toolbar, left, plus) = try await host(size: Metrics.screen)
        let leftGlass = left.glass
        let plusGlass = try XCTUnwrap(plus.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        app.chrome.setFolded(true)
        try await stable(left, plus, leftGlass: leftGlass, plusGlass: plusGlass,
                         expectedID: nil, name: "Actual folded source, no replaced buttons")
        XCTAssertTrue(app.chrome.folded)
        let source = ChromeGeometry(size: toolbar.bounds.size, folded: true, hasNow: app.nowItem != nil)
        XCTAssertNil(toolbar.hitTest(CGPoint(x: source.back.midX, y: source.back.midY), with: nil))
        XCTAssertNil(toolbar.hitTest(CGPoint(x: source.space.midX, y: source.space.midY), with: nil), "folded controls cannot consume the page's former side regions")
        app.chrome.setFolded(false)
        try await stable(left, plus, leftGlass: leftGlass, plusGlass: plusGlass,
                         expectedID: "chrome.plus", name: "Actual source unfolds with original controls")
    }

    func testCoveredControlRejectsTapAndReenabledControlAcceptsIt() async throws {
        let (app, _, left, plus) = try await host(size: Metrics.screen)
        let ready = await until { plus.menu != nil && plus.accessibilityIdentifier == "chrome.plus" }
        XCTAssertTrue(ready)
        // Other tabs are open: the button is the tab stack, its own native hold
        // menu in inline groups and its VoiceOver actions.
        XCTAssertTrue(plus.isContextMenuInteractionEnabled, "the stack keeps its native hold menu")
        XCTAssertNotNil(plus.menu?.children.compactMap { ($0 as? UIMenu)?.children.first as? UIAction }.first)
        XCTAssertEqual(plus.accessibilityCustomActions?.map(\.name), ["Switch to Previous Tab", "Show All Tabs", "New Tab"])
        app.surfaces.openSettings()
        let covered = await until { !plus.isEnabled && !left.isEnabled }
        XCTAssertTrue(covered)
        plus.sendActions(for: .touchUpInside)
        XCTAssertNil(app.surfaces.field)
        app.surfaces.closeSettings()
        let enabled = await until { plus.accessibilityIdentifier == "chrome.plus" && plus.isEnabled }
        XCTAssertTrue(enabled)
        plus.sendActions(for: .touchUpInside)
        XCTAssertNil(app.surfaces.field)
        // All Tabs opens once the page in front is pictured for its card.
        let gallery = await until { TabStack.of(app).gallery != nil }
        XCTAssertTrue(gallery, "the same reenabled native control still accepts its intended tap: All Tabs")
    }

    func testWindowGesturesRejectOtherMountedAndPresentedNativeHierarchies() async throws {
        let (app, _, left, plus) = try await host(size: Metrics.screen)
        let owned = try XCTUnwrap(window)
        let installed = await until { owned.gestureRecognizers?.contains { $0.delegate is PlateGestures } == true }
        XCTAssertTrue(installed, "the chrome's host installs the plate's recognizer on its window")
        let pan = try XCTUnwrap(owned.gestureRecognizers?.compactMap { $0 as? UIPanGestureRecognizer }.first { $0.delegate is PlateGestures })
        let gestures = try XCTUnwrap(pan.delegate as? PlateGestures)
        func center(_ view: UIView) -> CGPoint { view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: owned) }
        let ready = await until { plus.accessibilityIdentifier == "chrome.plus" }
        XCTAssertTrue(ready)
        XCTAssertTrue(gestures.receive(at: center(left), touched: left, in: owned))
        XCTAssertTrue(gestures.receive(at: center(plus), touched: plus, in: owned))
        let host = try XCTUnwrap(owned.rootViewController)
        let cover = UIView(frame: host.view.bounds)
        host.view.addSubview(cover)
        XCTAssertTrue(cover.window === owned)
        XCTAssertFalse(gestures.receive(at: center(plus), touched: cover, in: owned), "a sibling surface cannot lend the toolbar its touch")
        cover.removeFromSuperview()
        let alert = UIAlertController(title: "Owned native modal", message: "Gesture ownership probe", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        host.present(alert, animated: false)
        let appeared = await until { alert.viewIfLoaded?.window === owned }
        XCTAssertTrue(appeared)
        XCTAssertFalse(gestures.receive(at: center(plus), touched: alert.view, in: owned), "the actual presented native hierarchy is not the toolbar")
        let independent = PlateGestures(app: app)
        independent.install(on: owned)
        independent.uninstall()
        XCTAssertTrue(PlateGestures.installed, "removing one owner cannot retire the surviving actual root window's recognizer")
        alert.dismiss(animated: false)
    }

    /// Check the actual mounted UIButton and its drawn glyph, beyond identity.
    func testNativePlusGlyphRemainsAboveItsGlass() async throws {
        // No other tab open in Work: the right button is + (Tabs/TabStack).
        let (_, _, _, plus) = try await host(size: CGSize(width: 375, height: 812)) { app in
            for tab in app.browser.space.today { app.browser.close(tab.id) }
        }
        let owned = try XCTUnwrap(window)
        func renderedGlyph(_ name: String, expectedID: String) async throws {
            let ready = await until { plus.accessibilityIdentifier == expectedID && plus.isEnabled }
            XCTAssertTrue(ready, name)
            owned.layoutIfNeeded(); plus.layoutIfNeeded()
            let image = try XCTUnwrap(plus.imageView)
            let glass = try XCTUnwrap(plus.subviews.compactMap { $0 as? UIVisualEffectView }.first)
            XCTAssertNotNil(plus.currentImage)
            XCTAssertTrue(image.superview === plus)
            XCTAssertGreaterThan(try XCTUnwrap(plus.subviews.firstIndex(of: image)),
                                 try XCTUnwrap(plus.subviews.firstIndex(of: glass)))
            XCTAssertFalse(image.isHidden)
            XCTAssertEqual(image.alpha, 1)
            let imageFrame = image.convert(image.bounds, to: owned)
            let buttonFrame = plus.convert(plus.bounds, to: owned)
            XCTAssertTrue(buttonFrame.contains(imageFrame))
            XCTAssertEqual(imageFrame.midX, buttonFrame.midX, accuracy: 0.01)
            XCTAssertEqual(imageFrame.midY, buttonFrame.midY, accuracy: 0.01)
            func capture() throws -> UIImage {
                let full = UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
                    XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
                }
                let scale = full.scale
                let rect = CGRect(x: imageFrame.minX * scale, y: imageFrame.minY * scale,
                                  width: imageFrame.width * scale, height: imageFrame.height * scale)
                let crop = try XCTUnwrap(full.cgImage?.cropping(to: rect))
                return UIImage(cgImage: crop, scale: scale, orientation: .up)
            }
            let visible = try capture()
            image.isHidden = true
            let absent: UIImage
            do { absent = try capture() } catch { image.isHidden = false; throw error }
            image.isHidden = false
            func rgba(_ image: UIImage) throws -> [UInt8] {
                let cg = try XCTUnwrap(image.cgImage)
                var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                try bytes.withUnsafeMutableBytes { raw in
                    let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                }
                return bytes
            }
            let ink = try rgba(visible), material = try rgba(absent)
            XCTAssertEqual(ink.count, material.count)
            var foreground = 0
            for pixel in stride(from: 0, to: min(ink.count, material.count), by: 4) {
                let materialRGB = Int(material[pixel]) + Int(material[pixel + 1]) + Int(material[pixel + 2])
                let inkRGB = Int(ink[pixel]) + Int(ink[pixel + 1]) + Int(ink[pixel + 2])
                if materialRGB - inkRGB > 180 { foreground += 1 }
            }
            var chain: [String] = []
            var node: UIView? = plus
            while let view = node { chain.append("\(type(of: view)) a=\(view.alpha) h=\(view.isHidden)"); node = view.superview }
            XCTAssertGreaterThan(foreground, 20, "the real glyph must contribute primary ink above the same material; "
                + "image=\(imageFrame) field=\(String(describing: ownedApp?.surfaces.field)) folded=\(ownedApp?.chrome.folded == true) "
                + chain.joined(separator: " < "))
            let attachment = XCTAttachment(image: visible)
            attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        try await renderedGlyph("Actual Plus source native glyph", expectedID: "chrome.plus")
    }

    /// With other tabs open the same button draws the tab stack instead of +,
    /// its two cards on its glass circle, and says so; lent to All Tabs, it
    /// draws nothing (TabGalleryLayer draws the circle meanwhile).
    func testTheStackIsDrawnOverTheGlassInsteadOfTheGlyph() async throws {
        let (_, _, _, plus) = try await host(size: CGSize(width: 375, height: 812))
        let owned = try XCTUnwrap(window)
        let ready = await until { plus.accessibilityIdentifier == "chrome.plus" && plus.isEnabled }
        XCTAssertTrue(ready)
        owned.layoutIfNeeded(); plus.layoutIfNeeded()
        let glass = try XCTUnwrap(plus.subviews.compactMap { $0 as? UIVisualEffectView }.first)
        XCTAssertTrue(plus.stackView.superview === plus)
        XCTAssertGreaterThan(try XCTUnwrap(plus.subviews.firstIndex(of: plus.stackView)),
                             try XCTUnwrap(plus.subviews.firstIndex(of: glass)))
        XCTAssertEqual(plus.stackView.alpha, 1)
        XCTAssertEqual(glass.alpha, 1, "the glass circle stays under the stack")
        XCTAssertEqual(plus.imageView?.alpha, 0)
        XCTAssertTrue(plus.accessibilityLabel?.hasPrefix("Previous tab, ") == true)
        plus.lent = true
        XCTAssertEqual(glass.alpha, 0)
        XCTAssertEqual(plus.stackView.alpha, 0)
        XCTAssertEqual(plus.imageView?.alpha, 0)
        plus.lent = false
        XCTAssertEqual(glass.alpha, 1)
        XCTAssertEqual(plus.stackView.alpha, 1)
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: plus.convert(plus.bounds, to: owned)).image { _ in
            XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
        })
        attachment.name = "Actual stack on the page"; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// The folded material is Safari's 31 points (Metrics.Chrome.minHeight); the retained native button must
    /// actually own the 44-point target including its vertical padding.
    func testFoldedRetainedCenterOwnsRealFortyFourPointPadding() async throws {
        let (app, _, _, _) = try await host(size: CGSize(width: 375, height: 812))
        let owned = try XCTUnwrap(window)
        let mounted = await until { self.views(owned).filter { $0 is ToolbarPlateButton }.count == 1 }
        XCTAssertTrue(mounted)
        let center = try XCTUnwrap(views(owned).compactMap { $0 as? ToolbarPlateButton }.first)
        let words = center.words
        let sourceID = app.browser.tab?.id
        app.chrome.setFolded(true)
        func actualTarget(_ name: String) async throws {
            let ready = await until { center.accessibilityIdentifier == "chrome.plate"
                && center.accessibilityValue == "folded" && center.isEnabled
                && abs(center.bounds.height - Metrics.touch) < 0.001 }
            XCTAssertTrue(ready, name)
            owned.layoutIfNeeded()
            XCTAssertTrue(self.views(owned).compactMap { $0 as? ToolbarPlateButton }.first === center)
            XCTAssertTrue(center.words === words)
            XCTAssertEqual(center.bounds.height, 44, accuracy: 0.001)
            XCTAssertEqual(center.accessibilityFrame.height, 44, accuracy: 0.001)
            let painted = ChromeGeometry(size: owned.bounds.size, folded: true, hasNow: app.nowItem != nil).plate
            XCTAssertEqual(painted.height, Metrics.Chrome.minHeight, accuracy: 0.001)
            let frame = center.convert(center.bounds, to: owned)
            XCTAssertEqual(frame.midY, painted.midY, accuracy: 0.5)
            for dy: CGFloat in [-20, 20] {
                let point = CGPoint(x: frame.midX, y: frame.midY + dy)
                XCTAssertTrue(frame.contains(point))
                XCTAssertFalse(painted.contains(point), "the touch is outside the smaller painted material")
                let hit = owned.hitTest(point, with: nil)
                XCTAssertTrue(hit === center || hit?.isDescendant(of: center) == true,
                              "the native window must route the padding to its actual retained button")
            }
            let facts = XCTAttachment(string: "actualNative=\(frame), AX=\(center.accessibilityFrame), material=\(painted)")
            facts.name = name + " actual native padding authority"; facts.lifetime = .keepAlways; add(facts)
            let picture = XCTAttachment(image: UIGraphicsImageRenderer(bounds: owned.bounds).image { _ in
                XCTAssertTrue(owned.drawHierarchy(in: owned.bounds, afterScreenUpdates: true))
            })
            picture.name = name; picture.lifetime = .keepAlways; add(picture)
        }
        try await actualTarget("Actual folded material inside native44 target")
        XCTAssertEqual(app.browser.tab?.id, sourceID)
        center.sendActions(for: .touchUpInside)
        let opened = await until { app.surfaces.field != nil }
        XCTAssertTrue(opened)
        XCTAssertEqual(app.browser.tab?.id, sourceID)
    }
}
