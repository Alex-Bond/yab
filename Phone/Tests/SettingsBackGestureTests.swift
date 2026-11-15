import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Test the production origin policy against actual native hit views.
/// The real SettingsRootTests finger journey separately proves gesture mounting,
/// slider ownership and an empty-edge Back. The untouched unit-test host has no
/// mounted SettingsBackPan in its actual hierarchy on SDK27; its existence is
/// not evidence obtainable from this host before a real pointer interaction.
@MainActor
final class SettingsBackGestureTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var previousNavigation: [SettingsRoute] = []

    override func setUp() {
        previousNavigation = SettingsUI.shared.navigation
        SettingsUI.shared.navigation = [.page(.appearance)]
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        if let scene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen)) }
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIHostingController(rootView: NativeControls())
        window.makeKeyAndVisible()
    }

    override func tearDown() {
        window.endEditing(true)
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        SettingsUI.shared.navigation = previousNavigation
    }

    func testRealNativeControlHitViewsAreExcludedByTheProductionBackPolicy() async throws {
        try await eventually {
            let actual = self.views(self.window)
            return actual.contains { $0 is UISlider }
                && actual.contains { $0 is UISwitch }
                && actual.contains { $0 is UITextField }
                && actual.contains { $0 is UITextView }
        }
        let actual = views(window)
        let slider = try XCTUnwrap(actual.compactMap { $0 as? UISlider }.first)
        slider.value = 0
        let track = slider.trackRect(forBounds: slider.bounds)
        let thumb = slider.thumbRect(forBounds: slider.bounds, trackRect: track, value: 0)
        let controls: [(UIView, CGPoint)] = [
            (slider, CGPoint(x: thumb.midX, y: thumb.midY)),
            (try XCTUnwrap(actual.compactMap { $0 as? UISwitch }.first), .zero),
            (try XCTUnwrap(actual.compactMap { $0 as? UITextField }.first), .zero),
            (try XCTUnwrap(actual.compactMap { $0 as? UITextView }.first), .zero)
        ]
        let mountingView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(mountingView.window === window)
        let owner = SettingsBackGesture.Coordinator(route: .page(.appearance))
        for (control, thumb) in controls {
            let point = thumb == .zero ? CGPoint(x: control.bounds.midX, y: control.bounds.midY) : thumb
            let hit = try XCTUnwrap(window.hitTest(control.convert(point, to: window), with: nil))
            XCTAssertTrue(hit.isDescendant(of: mountingView), "the native control must belong to the real gesture owner")
            XCTAssertFalse(owner.acceptsOrigin(hit), "the actual \(type(of: control)) touch must stay with its control")
        }
    }

    func testRealEmptyPageHitViewIsAcceptedByTheProductionBackPolicy() async throws {
        try await eventually {
            self.window.rootViewController?.view.bounds.width == self.window.bounds.width
        }
        let hit = try XCTUnwrap(window.hitTest(CGPoint(x: 2, y: window.bounds.maxY - 50), with: nil))
        let mountingView = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertTrue(mountingView.window === window)
        XCTAssertTrue(hit.isDescendant(of: mountingView))
        XCTAssertTrue(SettingsBackGesture.Coordinator(route: .page(.appearance)).acceptsOrigin(hit))
    }

    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { views($0) } }
    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(16))
        }
        if !condition() {
            let hierarchy = views(window).map { view in
                "\(type(of: view)) frame=\(view.frame) recognizers="
                    + (view.gestureRecognizers ?? []).map { String(describing: type(of: $0)) }.joined(separator: ",")
            }.joined(separator: "\n")
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "owned-native-back-gesture-mount"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(condition(), "the actual native controls did not mount")
    }
}

private struct NativeControls: View {
    @State private var amount = 0.0
    @State private var on = false
    @State private var words = "Owned field"
    @State private var draft = "Owned draft"
    var body: some View {
        VStack {
            Slider(value: $amount).frame(height: 44)
            Toggle("Owned switch", isOn: $on)
            TextField("Owned field", text: $words).frame(height: 44)
            TextEditor(text: $draft).frame(height: 80)
            Spacer()
        }.padding(.top, 60)
            .padding(.horizontal, 12)
            .background(Color.white)
            .gesture(SettingsBackGesture(route: .page(.appearance)))
    }
}
