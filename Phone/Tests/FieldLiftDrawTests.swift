import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// A swipe up on the plate always ends with the spaces drawn, whatever else
/// SwiftUI was holding when it began. Once in a while in the farm the chrome
/// gave way to the lift and nothing came: no spaces, no field, no chrome to
/// touch (49ce6fb8b6484bd9, 3dafdd91612f47d9). FieldLayer had been drawn
/// inside `shown`'s willSet, with the old value, while SwiftUI flushed an
/// update of another transaction there, and never heard `shown` change.
/// These tests start the lift with such a transaction around it or waiting.
@MainActor
final class FieldLiftDrawTests: XCTestCase {
    private var window: UIWindow?
    private weak var previousKey: UIWindow?
    private var oldDisabled = false
    private var oldWelcomed = false

    override func setUp() {
        oldDisabled = Motion.disabled; Motion.disabled = true
        oldWelcomed = SettingsStore.shared.welcomed; SettingsStore.shared.welcomed = true
    }

    override func tearDown() {
        window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); previousKey = nil
        Motion.disabled = oldDisabled
        SettingsStore.shared.welcomed = oldWelcomed
    }

    private func views(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(views) }

    private func until(_ seconds: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// The whole app's root over the page, as a person has it.
    private func host() async throws -> AppModel {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        previousKey = scene.windows.first(where: \.isKeyWindow)
        let app = AppModel(world: try World.load(named: "mira"))
        let owned = UIWindow(windowScene: scene)
        owned.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window = owned
        let root = UIHostingController(rootView: RootView().environment(app))
        root.safeAreaRegions = []
        owned.rootViewController = root
        owned.makeKeyAndVisible(); owned.layoutIfNeeded()
        let ready = await until { self.views(owned).contains { $0 is ToolbarPlateButton } }
        XCTAssertTrue(ready, "the chrome never stood")
        // Settled, with FieldLayer drawn once and waiting for `shown`.
        try await Task.sleep(for: .milliseconds(200))
        return app
    }

    /// The field's own input, there only while FieldLayer draws the field.
    private var input: UITextField? {
        window.flatMap { views($0).compactMap { $0 as? UITextField }.first { $0.accessibilityIdentifier == "field.input" } }
    }

    private func lift(_ app: AppModel) {
        app.field.beginLift()
        app.field.liftMoved(-300)
    }

    private func checkTheSpacesCame(_ app: AppModel, file: StaticString = #filePath, line: UInt = #line) async {
        app.field.liftEnded(-300, velocity: 0)
        XCTAssertEqual(app.surfaces.field, .newTab, file: file, line: line)
        XCTAssertEqual(app.field.spacesVeil, 1, "the chrome gave way", file: file, line: line)
        let drawn = await until { self.input != nil }
        XCTAssertTrue(drawn, "the chrome gave way to the lift and no field came", file: file, line: line)
    }

    func testALiftInsideAnotherTransactionDrawsTheSpaces() async throws {
        let app = try await host()
        withAnimation(.linear(duration: 0.3)) { lift(app) }
        await checkTheSpacesCame(app)
    }

    func testALiftWhileAnAnimatedChangeWaitsDrawsTheSpaces() async throws {
        let app = try await host()
        withAnimation(.linear(duration: 0.3)) { app.surfaces.scrim = 0.05 }
        lift(app)
        await checkTheSpacesCame(app)
    }

    func testALiftWhileAQuietChangeWaitsDrawsTheSpaces() async throws {
        let app = try await host()
        var quiet = Transaction(animation: nil)
        quiet.disablesAnimations = true
        withTransaction(quiet) { app.surfaces.scrim = 0.05 }
        lift(app)
        await checkTheSpacesCame(app)
    }

    /// Let go before the next turn (a busy main thread): a lift that falls
    /// back into the plate stays a fold, and ✕ can close the spaces after.
    func testALiftLetGoBeforeTheNextTurnFoldsBack() async throws {
        let app = try await host()
        Motion.disabled = false
        defer { Motion.disabled = true }
        app.field.beginLift()
        app.field.liftMoved(-40)
        app.field.liftEnded(-40, velocity: 0)
        let folded = await until(3) { app.surfaces.field == nil && !app.field.shown }
        XCTAssertTrue(folded, "a short lift folds back into the plate (field \(String(describing: app.surfaces.field)), reveal \(app.field.reveal))")
        XCTAssertNil(app.field.spacesVeil, "the chrome is back")
    }
}
