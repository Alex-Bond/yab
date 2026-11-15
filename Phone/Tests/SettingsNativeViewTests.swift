import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Exercise the real hosted navigation, native text and clear control. The
/// outer viewport is the sheet that is painted, rather than an AX-only frame.
@MainActor
final class SettingsNativeViewTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var app: AppModel!
    private var disabled = false

    override func setUp() async throws {
        disabled = Motion.disabled
        Motion.disabled = true
        SettingsUI.shared.settingsGone()
        SettingsUI.shared.sheet.show(from: nil)
        let id = UUID().uuidString
        let space = Space(id: id, name: "Research", emoji: "", tint: RGB(180, 190, 200))
        app = AppModel(world: World(name: id, space: id, spaces: [space]))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
    }

    override func tearDown() async throws {
        window?.endEditing(true)
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        app = nil
        SettingsUI.shared.sheet.dismissNow()
        SettingsUI.shared.settingsGone()
        Motion.disabled = disabled
    }

    func testBoundedStackKeepsRealSearchAndDraftThroughPushBackAndHostUpdate() async throws {
        let parent = UIViewController()
        window.rootViewController = parent
        let viewport = SettingsViewportController()
        let size = CGSize(width: window.bounds.width, height: window.bounds.height - Metrics.Settings.top)
        func content() -> AnyView {
            AnyView(SettingsSheet(size: size).environment(app).environment(\.dynamicTypeSize, .large))
        }
        viewport.update(content())
        parent.addChild(viewport)
        parent.view.addSubview(viewport.view)
        viewport.view.frame = CGRect(x: 0, y: Metrics.Settings.top, width: size.width, height: size.height)
        viewport.didMove(toParent: parent)
        window.makeKeyAndVisible()
        try await eventually { self.label("settings.title") != nil }
        XCTAssertEqual(viewport.view.convert(viewport.view.bounds, to: window), CGRect(x: 0, y: 60, width: size.width, height: size.height))
        XCTAssertTrue(viewport.view.clipsToBounds)
        XCTAssertEqual(viewport.view.accessibilityIdentifier, "settings.sheet")
        XCTAssertTrue(viewport.view.accessibilityViewIsModal)
        XCTAssertEqual(viewport.children.count, 1)
        XCTAssertEqual(viewport.children.first?.view.frame, viewport.view.bounds)

        let ui = SettingsUI.shared
        ui.search = "dark"
        ui.feedbackDraft = "Keep the same reviewable draft."
        try await eventually { self.views(self.window).contains { ($0 as? UITextField)?.text == "dark" } }
        ui.openPage(.appearance)
        try await eventually { self.label("settings.page.title")?.text == "Appearance" }
        viewport.update(content())
        ui.closePage()
        try await eventually {
            self.label("settings.title") != nil && self.views(self.window).contains { ($0 as? UITextField)?.text == "dark" }
        }
        XCTAssertEqual(ui.feedbackDraft, "Keep the same reviewable draft.")
        XCTAssertEqual(viewport.children.count, 1, "updates must keep the same navigation host mounted")
        attach("Bounded actual Settings stack after native push and Back")
    }

    func testRootAndHeroFontsGrowWithNativeTextStylesAndRetainTextMetadata() async throws {
        func content(_ size: DynamicTypeSize) -> AnyView {
            AnyView(VStack {
                SettingsText(words: "Settings", weight: .semibold, identifier: "native.root", isHeader: true)
                SettingsText(words: "Notifications", style: .title2, weight: .bold, identifier: "native.hero", isHeader: true)
            }.padding().environment(\.dynamicTypeSize, size))
        }
        let host = UIHostingController(rootView: content(.large))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await eventually { (self.label("native.hero")?.bounds.height ?? 0) > 0 }
        let root = try XCTUnwrap(label("native.root"))
        let hero = try XCTUnwrap(label("native.hero"))
        let before = hero.bounds.height
        host.rootView = content(.accessibility5)
        let category = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let expected = UIFont.preferredFont(forTextStyle: .title2, compatibleWith: category)
        try await eventually { hero.font.pointSize == expected.pointSize && hero.bounds.height >= hero.font.lineHeight }
        XCTAssertEqual(root.font.pointSize, UIFont.preferredFont(forTextStyle: .body, compatibleWith: category).pointSize)
        XCTAssertGreaterThan(hero.bounds.height, before)
        for label in [root, hero] {
            XCTAssertTrue(label.adjustsFontForContentSizeCategory)
            XCTAssertTrue(label.isAccessibilityElement)
            XCTAssertTrue(label.accessibilityTraits.contains(.header))
            XCTAssertNotNil(label.font.fontDescriptor.object(forKey: .textStyle))
            XCTAssertTrue(window.bounds.contains(label.convert(label.bounds, to: window)))
        }
        attach("Real semantic Settings words at largest Dynamic Type")
    }

    func testHeroTitleBoundsExcludeItsDecorativeTile() async throws {
        let host = UIHostingController(rootView: SettingsPageHeader(page: .notifications)
            .environment(app).environment(\.dynamicTypeSize, .large).padding(.horizontal, Metrics.Settings.bodySide))
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await eventually { (self.label("settings.page.title")?.bounds.height ?? 0) > 0 }
        let title = try XCTUnwrap(label("settings.page.title"))
        XCTAssertEqual(title.text, "Notifications")
        XCTAssertLessThan(title.bounds.height, Metrics.Settings.heroTile)
        XCTAssertLessThan(title.bounds.width, window.bounds.width - Metrics.Settings.bodySide * 2)
        XCTAssertEqual(title.convert(title.bounds, to: window).midX, window.bounds.midX, accuracy: 1)
        XCTAssertGreaterThanOrEqual(title.bounds.height, title.font.lineHeight)
        attach("Actual native title has text bounds, with tile drawn separately")
    }

    func testSearchClearOwnsItsWhole44PointTouchRegionAndCallsTheActionOnce() async throws {
        var calls = 0
        let host = UIHostingController(rootView: SettingsSearchClear { calls += 1 }
            .frame(width: Metrics.touch, height: Metrics.touch))
        window.rootViewController = host
        window.makeKeyAndVisible()
        var found: UIButton?
        try await eventually {
            found = self.views(self.window).compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "settings.search.clear" }
            return found?.bounds.size == CGSize(width: 44, height: 44)
        }
        let button = try XCTUnwrap(found)
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertEqual(button.accessibilityLabel, "Clear search")
        let edge = button.convert(CGPoint(x: 2, y: 2), to: window)
        XCTAssertTrue(window.hitTest(edge, with: nil) === button)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(calls, 1)
    }

    private func label(_ id: String) -> UILabel? {
        views(window).compactMap { $0 as? UILabel }.first { $0.accessibilityIdentifier == id }
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { views($0) } }
    private func eventually(_ condition: () -> Bool) async throws {
        let until = Date().addingTimeInterval(5)
        while !condition(), Date() < until {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        XCTAssertTrue(condition(), "the actual native hierarchy did not settle")
    }
    private func attach(_ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn)
        let picture = XCTAttachment(image: image)
        picture.name = name
        picture.lifetime = .keepAlways
        add(picture)
    }
}
