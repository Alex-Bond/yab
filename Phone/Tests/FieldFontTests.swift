import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// UIKit can resize the input before SwiftUI receives a new text category.
/// The visible pill must make room for that real font without losing the address.
@MainActor
final class FieldFontTests: XCTestCase {
    private var app: AppModel!
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var previousMotionDisabled = false
    private var previousForcedMotion = false

    override func setUp() async throws {
        previousMotionDisabled = Motion.disabled
        previousForcedMotion = FieldMotion.forced
        Motion.disabled = true
        FieldMotion.forced = false
        app = AppModel(world: try World.load(named: "mira"))
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        let host = UIHostingController(rootView: FieldLayer()
            .environment(app)
            .environment(\.dynamicTypeSize, .large))
        host.traitOverrides.preferredContentSizeCategory = .large
        window.rootViewController = host
        window.makeKeyAndVisible()
    }

    override func tearDown() async throws {
        window?.endEditing(true)
        app?.surfaces.closeField()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        app = nil
        Motion.disabled = previousMotionDisabled
        FieldMotion.forced = previousForcedMotion
    }

    func testNativeTraitChangeGrowsPillAndReturnsToDefault() async throws {
        let field = try await input()
        let address = try XCTUnwrap(field.text)
        try await settled(field, font: bodyFont(.large))
        let originalHeight = app.field.frame(in: window.bounds.size).height

        field.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settled(field, font: bodyFont(.accessibilityExtraExtraExtraLarge))
        XCTAssertGreaterThan(app.field.frame(in: window.bounds.size).height, originalHeight)
        XCTAssertEqual(field.text, address)
        XCTAssertTrue(app.field.showsAddress)
        XCTAssertEqual(selectedFont(in: field), field.font)

        field.traitOverrides.preferredContentSizeCategory = .large
        try await settled(field, font: bodyFont(.large))
        XCTAssertEqual(app.field.frame(in: window.bounds.size).height, originalHeight, accuracy: 0.5)
        XCTAssertEqual(field.text, address)
        XCTAssertEqual(selectedFont(in: field), field.font)
    }

    func testNativeFontChangeSurvivesSwiftUIRenderAndRestoresPill() async throws {
        let field = try await input(mode: .newTab, words: "sett")
        let words = try XCTUnwrap(field.text)
        let normal = bodyFont(.large)
        try await settled(field, font: normal)
        let originalHeight = app.field.frame(in: window.bounds.size).height
        XCTAssertEqual(field.traitCollection.preferredContentSizeCategory, .large)

        // Audits can adjust the native font while the hosting trait stays unchanged.
        // Two changes in one turn also exercise the coalesced latest-size report.
        field.font = bodyFont(.extraExtraExtraLarge)
        let large = bodyFont(.accessibilityExtraExtraExtraLarge)
        field.font = large
        try await settled(field, font: large)
        XCTAssertEqual(field.traitCollection.preferredContentSizeCategory, .large)
        XCTAssertGreaterThan(app.field.frame(in: window.bounds.size).height, originalHeight)
        XCTAssertEqual(field.text, words)
        XCTAssertFalse(app.field.showsAddress)

        field.font = normal
        try await settled(field, font: normal)
        XCTAssertEqual(app.field.frame(in: window.bounds.size).height, originalHeight, accuracy: 0.5)
        XCTAssertEqual(field.text, words)
        XCTAssertFalse(app.field.showsAddress)
    }

    func testEmptyNewTabHintFitsNativeLargeFontAndRestoresFullPurpose() async throws {
        let field = try await input(mode: .newTab, words: "sett")
        app.field.clear()
        let purpose = "Search, ask or give a task"
        try await settledHint(field, font: bodyFont(.large), purpose: purpose)
        XCTAssertEqual(field.placeholder, purpose)

        field.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settledHint(field, font: bodyFont(.accessibilityExtraExtraExtraLarge), purpose: purpose)
        attachLargeHint(field)
        assertShortened(field.placeholder, from: "Search…")
        XCTAssertEqual(field.text, "")
        XCTAssertEqual(field.accessibilityLabel, purpose)

        field.traitOverrides.preferredContentSizeCategory = .large
        try await settledHint(field, font: bodyFont(.large), purpose: purpose)
        XCTAssertEqual(field.placeholder, purpose)
        XCTAssertEqual(field.text, "")
    }

    func testAddressHintKeepsAddressPurposeAndSelectedText() async throws {
        let field = try await input(mode: .address)
        let address = field.text
        field.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settledHint(field, font: bodyFont(.accessibilityExtraExtraExtraLarge),
                              purpose: "Address, search, ask or give a task", empty: false)
        assertShortened(field.placeholder, from: "Address…")
        XCTAssertEqual(field.text, address)
        XCTAssertTrue(app.field.showsAddress)
        XCTAssertEqual(selectedFont(in: field), field.font)
    }

    func testEmptyPrivateHintFitsWithoutAdvertisingAskOrTasks() async throws {
        let privateField = try await input(mode: .newTab, words: "sett")
        app.field.setPrivate(true)
        app.field.clear()
        privateField.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settledHint(privateField, font: bodyFont(.accessibilityExtraExtraExtraLarge),
                              purpose: "Private search")
        XCTAssertTrue(app.field.isPrivate)
        XCTAssertEqual(privateField.text, "")
        XCTAssertFalse((privateField.placeholder ?? "").contains("ask"))
        XCTAssertFalse((privateField.accessibilityLabel ?? "").contains("task"))
    }

    func testPrivatePageAddressHintKeepsSearchOnlyPurposeAndSelectedText() async throws {
        app.openPrivately(PageFixtures.search("private test"))
        let field = try await input(mode: .address)
        let address = field.text
        field.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settledHint(field, font: bodyFont(.accessibilityExtraExtraExtraLarge),
                              purpose: "Address or private search", empty: false)
        XCTAssertTrue(app.field.pageIsPrivate)
        assertShortened(field.placeholder, from: "Search…")
        XCTAssertEqual(field.text, address)
        XCTAssertTrue(app.field.showsAddress)
        XCTAssertEqual(selectedFont(in: field), field.font)
    }

    private func settledHint(_ field: YabTextField, font: UIFont, purpose: String,
                             empty: Bool = true) async throws {
        try await settled(field, font: font)
        try await eventually("the native hint must fit without shrinking its font") {
            self.window.layoutIfNeeded()
            field.layoutIfNeeded()
            guard field.accessibilityLabel == purpose, !empty || field.text == "" else { return false }
            let size = ((field.placeholder ?? "") as NSString).size(withAttributes: [.font: font])
            return size.width <= field.textRect(forBounds: field.bounds).width + 0.01
        }
        XCTAssertEqual(field.font?.pointSize, font.pointSize)
        let size = ((field.placeholder ?? "") as NSString).size(withAttributes: [.font: font])
        XCTAssertLessThanOrEqual(size.width, field.textRect(forBounds: field.bounds).width + 0.01)
        XCTAssertEqual(field.accessibilityLabel, purpose)
    }

    /// At the largest sizes ✕ grows with the field (33be1e46: as tall as the
    /// field at any text size), so the compact hint may be cut further: it
    /// stays the compact hint's own start, at least two letters, then "…".
    private func assertShortened(_ placeholder: String?, from compact: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let hint = placeholder ?? ""
        let stem = compact.hasSuffix("…") ? String(compact.dropLast()) : compact
        XCTAssertTrue(hint == compact || (hint.hasSuffix("…") && hint.count >= 3 && stem.hasPrefix(String(hint.dropLast()))),
                      "\(hint) is not \(compact) or a shorter start of it", file: file, line: line)
    }

    private func attachLargeHint(_ field: YabTextField) {
        let font = field.font ?? UIFont.preferredFont(forTextStyle: .body)
        let hintWidth = ((field.placeholder ?? "") as NSString).size(withAttributes: [.font: font]).width
        let compactWidth = ("Search…" as NSString).size(withAttributes: [.font: font]).width
        let textRect = field.textRect(forBounds: field.bounds)
        let purposePreserved = field.accessibilityLabel == "Search, ask or give a task"
        let measurements = XCTAttachment(string: "Native font=\(font.pointSize), lineHeight=\(font.lineHeight), "
                                        + "fieldBounds=\(field.bounds), textRect=\(textRect), "
                                        + "hintWidth=\(hintWidth), requiredCompactWidth=\(compactWidth), "
                                        + "purposePreserved=\(purposePreserved)")
        measurements.name = "Largest native field font and available width"
        measurements.lifetime = .keepAlways
        add(measurements)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "the actual largest-font field hierarchy must render")
        let pixels = XCTAttachment(image: image)
        pixels.name = "Largest native New Tab hint beside a close control as tall as the field"
        pixels.lifetime = .keepAlways
        add(pixels)
    }

    private func bodyFont(_ category: UIContentSizeCategory) -> UIFont {
        UIFont.preferredFont(forTextStyle: .body,
                             compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    private func selectedFont(in field: UITextField) -> UIFont? {
        guard let text = field.attributedText, text.length > 0 else { return nil }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
    }

    private func input(mode: Surfaces.FieldMode = .address, words: String? = nil) async throws -> YabTextField {
        app.surfaces.openField(mode)
        if let words { app.field.typed(words) }
        var found: YabTextField?
        try await eventually("the native field must be installed") {
            found = self.findInput(in: self.window)
            return found?.window != nil && found?.text?.isEmpty == false
        }
        return try XCTUnwrap(found)
    }

    private func findInput(in view: UIView) -> YabTextField? {
        if let field = view as? YabTextField { return field }
        for child in view.subviews {
            if let field = findInput(in: child) { return field }
        }
        return nil
    }

    private func settled(_ field: YabTextField, font: UIFont) async throws {
        try await eventually("native font \(font.pointSize) must reach the visible field and its geometry") {
            self.window.layoutIfNeeded()
            field.layoutIfNeeded()
            return field.font?.pointSize == font.pointSize
                && abs(self.app.field.textScale - font.pointSize / Metrics.Field.font) < 0.001
                && field.bounds.height >= font.lineHeight
                && (!self.app.field.showsAddress || self.selectedFont(in: field)?.pointSize == font.pointSize)
        }
        XCTAssertGreaterThanOrEqual(field.bounds.height, font.lineHeight,
                                    "the real UITextField must contain its current line height")
    }

    private func eventually(_ message: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            if Date() >= deadline {
                XCTFail("\(message); font=\(String(describing: findInput(in: window)?.font)), "
                        + "frame=\(String(describing: findInput(in: window)?.frame)), scale=\(app.field.textScale)",
                        file: file, line: line)
                throw Timeout()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct Timeout: Error {}
}
