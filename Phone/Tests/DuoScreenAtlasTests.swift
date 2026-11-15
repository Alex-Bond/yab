import XCTest
import UIKit
@testable import YabPhone

/// Native app-window pictures at representative Duo bounds, not a Duo runtime.
/// Each named state starts in a fresh fixture world. No real account is touched.
@MainActor
final class DuoScreenAtlasTests: XCTestCase {
    /// The surfaces touched by the iPad workspace must retain the Duo layout.
    func testIPadChangesRegressionAtlas() async throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            throw XCTSkip("Duo uses phone traits; run this comparison on the phone simulator")
        }
        try await record(["page.1", "workspace.form", "field.1", "spaces.full", "stack.gallery",
                          "settings.page-appearance", "chats.page", "chat.3", "site.1", "welcome.5"])
        try await record(["page.1", "workspace.form", "field.1", "stack.gallery", "settings.page-appearance"], dark: true)
    }

    func testSettingsAtlas() async throws {
        let pages = SettingsPageID.allCases.map { "settings.page-\($0.rawValue)" }
        try await record(["settings.1", "settings.3", "settings.color", "settings.xxxl"] + pages)
    }

    func testTabStackAtlas() async throws {
        try await record(["stack.1", "stack.2", "stack.3", "stack.4", "stack.menu",
                          "stack.gallery", "stack.gallery.2", "stack.gallery.private"])
    }

    func testChatAtlas() async throws {
        try await record(["chats.page", "chats.search", "chat.1", "chat.2", "chat.3", "chat.6",
                          "chat.7", "chat.19", "chat.8", "chat.16", "chat.info", "chat.bubbles",
                          "chat.table", "chat.grid", "chat.10", "chat.info.long.3", "chat.info.long.4"])
    }

    func testBrowserSurfacesAtlas() async throws {
        try await record(["spaces.full", "newtab.private", "page.6", "site.1", "site.3"])
    }

    func testDarkAtlas() async throws {
        try await record(["settings.1", "settings.page-appearance", "stack.gallery", "chats.page", "chat.3", "chat.info"], dark: true)
    }

    func testTabStackMenuAfterRotation() async throws {
        try await record(["stack.menu"])
    }

    private func record(_ states: [String], dark: Bool = false) async throws {
        let motion = Motion.disabled
        let appearance = SettingsStore.shared.appearance
        let welcome = SettingsUI.shared.welcomeForced
        Motion.disabled = true
        defer {
            resetSurfaces()
            Motion.disabled = motion
            SettingsStore.shared.appearance = appearance
            SettingsUI.shared.welcomeForced = welcome
        }
        for name in states {
            resetSurfaces()
            SettingsStore.shared.appearance = dark ? .dark : .light
            try await recordState(name, dark: dark)
        }
    }

    private func recordState(_ name: String, dark: Bool) async throws {
        let state = try XCTUnwrap(StateCatalog.named(name), "Missing named state: \(name)")
        let app = AppModel(world: try World.load(named: "mira"))
        app.tasks.removeAll()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let root = RootController(app: app)
        root.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = root
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.frame = CGRect(x: 0, y: 0, width: 626, height: 890)
        window.makeKeyAndVisible()
        root.view.frame = window.bounds
        root.view.setNeedsLayout()
        root.view.layoutIfNeeded()
        defer {
            window.endEditing(true)
            root.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        try await Task.sleep(for: .milliseconds(250))
        await state.apply(app)
        let painted = await StateRunner.settle(app)
        XCTAssertTrue(painted, "Fixture did not paint for \(name)")
        // These pictures show the app at rest. The system keyboard lives in a
        // different window and is deliberately outside the app-window capture.
        app.field.rest()
        app.chatSheet.focused = false
        window.endEditing(true)
        for (orientation, size) in [("portrait", CGSize(width: 626, height: 890)),
                                    ("landscape", CGSize(width: 890, height: 626))] {
            window.frame.size = size
            root.view.frame = window.bounds
            root.view.setNeedsLayout()
            root.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(650))
            root.view.layoutIfNeeded()
            // UIKit dismisses its menu when the bounds change. Open it again
            // at the new anchor so the landscape picture shows the actual menu.
            if name == "stack.menu", orientation == "landscape" {
                TabStack.of(app).control?.presentMenuForTests()
                try await Task.sleep(for: .milliseconds(700))
            }
            XCTAssertFalse(app.workspace.tabletControls, "Duo must keep the phone controls")
            XCTAssertEqual(app.workspace.windowSize.width, size.width, accuracy: 1)
            XCTAssertEqual(app.workspace.windowSize.height, size.height, accuracy: 1)
            let label = "duo__\(dark ? "dark" : "light")__\(orientation)__\(name)"
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let photo = XCTAttachment(image: image)
            photo.name = label
            photo.lifetime = .keepAlways
            add(photo)
            let metadata: [String: Any] = ["name": label, "state": name, "title": state.title,
                "orientation": orientation, "appearance": dark ? "dark" : "light",
                "width": size.width, "height": size.height, "scale": image.scale,
                "native": true, "systemKeyboard": false, "actualDuoRuntime": false,
                "tabletControls": app.workspace.tabletControls, "painted": painted]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys, .prettyPrinted])
            let note = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            note.name = label
            note.lifetime = .keepAlways
            add(note)
            print("DUO_ATLAS \(label) \(Int(size.width))x\(Int(size.height))")
        }
    }

    private func resetSurfaces() {
        let ui = SettingsUI.shared
        ui.afterClose = nil
        ui.sheet.dismissNow()
        ui.join.dismissNow()
        ui.settingsGone()
        ui.welcomeForced = false
        ui.noMac = false
        ui.confirmClearData = false
        ui.backDrag = 0
        ui.typeSize = nil
        ui.scrollTarget = nil
        ui.scrolled = false
        ui.rootUnder = false
        ui.pageUnder = false
        ui.namingNew = nil
        ui.appIconPreview = nil
        ui.appIconPreviewDark = nil
        ui.assumeDefaultBrowser = false
        ui.assumeReports = false
        AboutModel.shared.shown = false
        FirstRun.shared.reset()
        let pager = NewTabPager.shared
        pager.startAt = nil
        pager.startFolded = false
        pager.position = 1
        pager.spaceID = nil
        pager.jump = nil
        pager.onChats = false
        pager.activeFieldMode = nil
        pager.showsArchive = false
        ChatInfoScroll.tab = nil
        PrivateNewTab.tryingForStates = false
        PrivateNewTab.listedForStates = false
    }
}
