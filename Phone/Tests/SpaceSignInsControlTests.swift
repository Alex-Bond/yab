import SwiftUI
import UIKit
import WebKit
import XCTest
@testable import YabPhone

/// Real native alert/window ownership with disposable profile namespaces.
@MainActor
final class SpaceSignInsControlTests: XCTestCase {
    private var window: UIWindow!
    private var marker: UIView!
    private var change: SpaceSignInsChange!
    private weak var previousKey: UIWindow?
    private var apps: [AppModel] = []
    private var folders: [URL] = []
    private var namespaces = Set<UUID>()
    private var oldPath: [SettingsRoute] = []
    private var oldDisabled = false

    override func setUp() async throws {
        oldDisabled = Motion.disabled; Motion.disabled = true
        oldPath = SettingsUI.shared.navigation; SettingsUI.shared.navigation = []
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = try XCTUnwrap(scenes.first { $0.activationState == .foregroundActive },
            "no active scene: " + scenes.map { scene in
                "\(scene.activationState.rawValue) " + scene.windows.map {
                    "\(type(of: $0)) key=\($0.isKeyWindow) hidden=\($0.isHidden) presented=\(String(describing: $0.rootViewController?.presentedViewController))"
                }.joined(separator: ", ")
            }.joined(separator: "; ") + " app=\(UIApplication.shared.applicationState.rawValue)")
        previousKey = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene); window.frame = CGRect(origin: .zero, size: Metrics.screen)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        marker = UIView(frame: .zero); window.rootViewController!.view.addSubview(marker)
        change = SpaceSignInsChange(); change.bind(marker)
        window.layoutIfNeeded()
    }
    private final class Lease { weak var app: AppModel?; init(_ app: AppModel) { self.app = app } }
    override func tearDown() async throws {
        change?.cancel(); if let marker { change?.detach(marker) }; change = nil
        let leases = apps.map(Lease.init)
        await releaseApps()
        window?.rootViewController?.dismiss(animated: false)
        marker?.removeFromSuperview(); marker = nil; window?.isHidden = true; window?.rootViewController = nil; window = nil
        previousKey?.makeKey(); SettingsUI.shared.navigation = oldPath; Motion.disabled = oldDisabled
        let deadline = Date().addingTimeInterval(5)
        while leases.contains(where: { $0.app != nil }), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard leases.allSatisfy({ $0.app == nil }) else { XCTFail("Owned App still retained; namespace/profile cleanup refused"); return }
        for id in namespaces {
            let end = Date().addingTimeInterval(5)
            while true {
                do { try await WKWebsiteDataStore.remove(forIdentifier: id); break }
                catch {
                    let e = error as NSError
                    guard e.domain == "WKWebSiteDataStore", e.code == 1,
                          e.localizedDescription.localizedCaseInsensitiveContains("in use"), Date() < end else { throw error }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
        }
        for folder in folders { try FileManager.default.removeItem(at: folder) }
    }
    private func releaseApps() async {
        for app in apps { for tab in app.browser.allTabs { app.pages.forget(tab.id) }; await app.flushProfile() }
        apps = []
    }
    private func makeApp(empty: Bool = false, identity: Bool = true) throws -> AppModel {
        let folder = URL(fileURLWithPath: "/private/tmp/yab-space-signins-controls-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); folders.append(folder)
        if !identity { try Data("owned corrupt identity".utf8).write(to: folder.appendingPathComponent("website-data-store.json")) }
        let profile = BrowserProfile(folder: folder)
        let tab = Tab(id: "owned.target", title: "Owned source", site: "Owned source", icon: "globe", url: "about:blank#source")
        let other = Tab(id: "owned.other", title: "Other", site: "Other", icon: "globe", url: "about:blank#other")
        let spaces = [Space(id: "target", name: "Research", emoji: "📚", tint: RGB(1, 2, 3),
                            today: empty ? [] : [tab], current: empty ? nil : tab.id),
                      Space(id: "other", name: "Other", emoji: "", tint: RGB(4, 5, 6), today: [other], current: other.id)]
        let app = AppModel(world: World(name: "owned sign-ins", space: "other", spaces: spaces, mac: .init(joined: false)),
                           fixturesEnabled: false, profile: profile, privateLockEnabled: { false })
        apps.append(app)
        for space in spaces { if let id = profile.websiteStoreID(for: space) { namespaces.insert(id) }; var own = space; own.ownSignIns = true; if let id = profile.websiteStoreID(for: own) { namespaces.insert(id) } }
        return app
    }
    private func settings(_ app: AppModel) { app.surfaces.openSettings(); SettingsUI.shared.navigation = [.page(.spaces), .space("target")] }
    private func request(_ app: AppModel, own: Bool = true, route: SpaceSignInsChange.Route = .settings) async throws -> UUID {
        guard case let .confirmation(id) = change.request(own: own, in: app, spaceID: "target", route: route) else {
            XCTFail("Real target with pages must ask before changing its namespace"); throw NSError(domain: "OwnedSignIns", code: 1)
        }
        let end = Date().addingTimeInterval(5)
        while window.rootViewController?.presentedViewController?.isBeingPresented == true, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        let alert = try XCTUnwrap(window.rootViewController?.presentedViewController as? UIAlertController)
        XCTAssertEqual(alert.title, "Change Sign-ins?")
        XCTAssertTrue(alert.message?.contains("Unsaved changes may be lost") == true)
        XCTAssertEqual(alert.actions.map(\.title), ["Cancel", "Change Sign-ins"])
        return id
    }
    private func dismissed() async throws {
        let end = Date().addingTimeInterval(5)
        while window.rootViewController?.presentedViewController != nil, Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(window.rootViewController?.presentedViewController)
    }

    func testVisibleSettingsCanChangeAnotherPublicSpaceWithoutSelectingItOrOverwritingItsMetadata() async throws {
        let app = try makeApp(); settings(app)
        let before = try XCTUnwrap(app.browser.space("target")), selected = app.browser.tab?.id
        let history = BrowserNavigation(entries: [.init(url: "about:blank#source", title: "Source", scrollY: 137)], index: 0)
        app.profile?.capture(app.browser); app.profile?.navigationChanged("owned.target", history)
        let identity = try Data(contentsOf: try XCTUnwrap(app.profile).folder.appendingPathComponent("website-data-store.json"))
        let store = app.pages.configurationForPage(in: before).websiteDataStore
        let id = try await request(app)
        XCTAssertTrue(change.confirm(id)); XCTAssertFalse(change.confirm(id))
        let after = try XCTUnwrap(app.browser.space("target"))
        XCTAssertTrue(after.ownSignIns); XCTAssertEqual(after.name, before.name); XCTAssertEqual(after.emoji, before.emoji)
        XCTAssertEqual(after.tint, before.tint); XCTAssertEqual(after.look, before.look)
        XCTAssertEqual(after.allTabs, before.allTabs); XCTAssertEqual(after.current, before.current)
        XCTAssertEqual(app.browser.spaceID, "other"); XCTAssertEqual(app.browser.tab?.id, selected)
        XCTAssertFalse(app.pages.configurationForPage(in: after).websiteDataStore === store)
        XCTAssertEqual(app.profile?.navigation["owned.target"]?.entries, history.entries)
        XCTAssertEqual(app.profile?.navigation["owned.target"]?.index, history.index)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(app.profile).folder.appendingPathComponent("website-data-store.json")), identity)
    }
    func testCancelPreservesTheOriginalStoreAndOldActionCannotConfirmANewRequest() async throws {
        let app = try makeApp(); settings(app)
        let old = try await request(app); change.cancel(); try await dismissed()
        XCTAssertFalse(change.confirm(old)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
        let fresh = try await request(app)
        XCTAssertFalse(change.confirm(old)); XCTAssertTrue(change.confirm(fresh))
    }
    func testSettingsPathChangedAwayAndBackRetiresTheCapturedNativeAction() async throws {
        let app = try makeApp(); settings(app); let id = try await request(app)
        let path = SettingsUI.shared.navigation
        SettingsUI.shared.navigation = [.page(.privacy)]
        SettingsUI.shared.navigation = path
        XCTAssertFalse(change.confirm(id)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
    }
    func testSelectedOwnerChangedAwayAndBackCannotReuseAnOldConfirmation() async throws {
        let app = try makeApp(); settings(app); let id = try await request(app)
        app.browser.showSpace("target"); app.browser.showSpace("other")
        XCTAssertFalse(change.confirm(id)); XCTAssertEqual(app.browser.spaceID, "other")
        XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
    }
    func testRemovedTargetAndChangedDomainCannotBeResurrectedByTheAlert() async throws {
        let app = try makeApp(); settings(app); let id = try await request(app)
        let removed = try XCTUnwrap(app.browser.space("target"))
        app.browser.adopt(app.browser.spaces.filter { $0.id != "target" })
        app.browser.adopt(app.browser.spaces + [removed])
        XCTAssertFalse(change.confirm(id)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
        change.cancel(); try await dismissed()
        let fresh = try await request(app)
        app.browser.setSpaceSignIns("target", own: true); app.browser.setSpaceSignIns("target", own: false)
        XCTAssertFalse(change.confirm(fresh)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
    }
    func testNativeWindowRetirementRefusesTheOldAction() async throws {
        let app = try makeApp(); settings(app); let id = try await request(app)
        window.isHidden = true
        XCTAssertFalse(change.confirm(id)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
    }
    func testDetachedActualMarkerCannotConfirmFromAnotherWindow() async throws {
        let app = try makeApp(); settings(app); let id = try await request(app)
        change.detach(marker); marker.removeFromSuperview()
        XCTAssertFalse(change.confirm(id)); XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
    }
    func testPrivateAndMissingPersistentIdentityCannotChangeOrPresentAnAlert() throws {
        let app = try makeApp(identity: false); settings(app)
        let bytes = try Data(contentsOf: try XCTUnwrap(app.profile).folder.appendingPathComponent("website-data-store.json"))
        XCTAssertNil(app.profile?.dataStoreID)
        XCTAssertEqual(change.request(own: true, in: app, spaceID: "target", route: .settings), .unavailable)
        let privateID = try XCTUnwrap(app.browser.spaces.first(where: \.isPrivate)?.id)
        XCTAssertEqual(change.request(own: true, in: app, spaceID: privateID, route: .settings), .unavailable)
        XCTAssertNil(window.rootViewController?.presentedViewController)
        XCTAssertFalse(try XCTUnwrap(app.browser.space("target")).ownSignIns)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(app.profile).folder.appendingPathComponent("website-data-store.json")), bytes)
    }
    func testRetainedChangeAndNativeAlertDoNotKeepTheAppOrItsProfileAlive() async throws {
        var app: AppModel? = try makeApp()
        settings(try XCTUnwrap(app))
        let id = try await request(try XCTUnwrap(app))
        weak var owner = app
        weak var profile = app?.profile
        await app?.flushProfile()
        apps.removeAll { $0 === app }; app = nil
        let end = Date().addingTimeInterval(5)
        while (owner != nil || profile != nil), Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(owner); XCTAssertNil(profile)
        XCTAssertFalse(change.confirm(id))
    }
    func testEmptyPublicTargetChangesOnlyItsFlagWithoutInventingAFormSafetyResult() throws {
        let app = try makeApp(empty: true); settings(app)
        XCTAssertEqual(change.request(own: true, in: app, spaceID: "target", route: .settings), .changed)
        XCTAssertTrue(try XCTUnwrap(app.browser.space("target")).ownSignIns)
        XCTAssertEqual(app.browser.spaceID, "other"); XCTAssertNil(window.rootViewController?.presentedViewController)
    }
}
