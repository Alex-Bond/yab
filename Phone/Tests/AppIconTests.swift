import SwiftUI
import SyncKit
import UIKit
import XCTest
@testable import YabPhone

@MainActor
final class AppIconTests: XCTestCase {
    func testActualCompiledAlternateIconsAndFullResolutionPreviewsExist() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        let expected = Set(PhoneAppIcon.allCases.compactMap(\.alternateName)).union(PhoneAppIcon.charmAlternates)
        XCTAssertEqual(Set(alternates.keys), expected)
        XCTAssertEqual(expected.count, 72)
        XCTAssertEqual(PhoneAppIcon.allCases.first, .flat)
        XCTAssertNil(PhoneAppIcon.flat.alternateName, "Flat is the primary AppIcon")
        XCTAssertTrue(UIApplication.shared.supportsAlternateIcons)
        for icon in PhoneAppIcon.allCases {
            for dark in [false, true] {
                let image = try XCTUnwrap(icon.picture(dark: dark), "Missing real artwork \(icon.rawValue)")
                let pixels = try XCTUnwrap(image.cgImage)
                XCTAssertEqual(pixels.width, 1024); XCTAssertEqual(pixels.height, 1024)
            }
        }
        for name in expected {
            let entry = try XCTUnwrap(alternates[name] as? [String: Any])
            XCTAssertEqual(try XCTUnwrap(entry["CFBundleIconName"] as? String), name,
                           "The actual asset compiler must bind this alternate to its exact catalog name")
            if let files = entry["CFBundleIconFiles"] as? [String] {
                XCTAssertFalse(files.isEmpty)
                XCTAssertTrue(files.contains { UIImage(named: $0) != nil })
            } else {
                let catalog = try XCTUnwrap(Bundle.main.url(forResource: "Assets", withExtension: "car"))
                let size = try catalog.resourceValues(forKeys: [.fileSizeKey]).fileSize
                XCTAssertGreaterThan(try XCTUnwrap(size), 0, "Catalog-backed icons need the actual packaged asset catalog")
            }
        }
    }

    func testActualAssetTraitsSelectExistingDarkArtworkAndUnknownNativeNameIsNotDefault() throws {
        for icon in [PhoneAppIcon.flat, .watercolorGlass] {
            let light = try XCTUnwrap(icon.picture(dark: false)?.pngData())
            let dark = try XCTUnwrap(icon.picture(dark: true)?.pngData())
            XCTAssertNotEqual(light, dark, "This catalog must select the existing dark artwork")
        }
        XCTAssertNil(PhoneAppIcon.current("unknown-installed-icon"))
        XCTAssertEqual(PhoneAppIcon.current(nil), .flat, "Flat is the primary icon")
        XCTAssertEqual(PhoneAppIcon.current("YabFlat"), .flat, "an earlier build's Flat choice")
        for icon in PhoneAppIcon.allCases { XCTAssertEqual(PhoneAppIcon.current(icon.alternateName), icon) }
        for name in PhoneAppIcon.charmAlternates { XCTAssertEqual(PhoneAppIcon.current(name), .charm) }
    }

    /// App Icon is a root row of its own under Appearance, ink only, and
    /// Appearance no longer holds it; without alternate icons there is no row.
    func testAppIconIsItsOwnRootRowAndOpensItsPageWithoutChangingTheSystemIcon() throws {
        let ui = SettingsUI.shared
        let previous = ui.navigation
        let spot = ui.searchSpot
        let actualName = UIApplication.shared.alternateIconName
        defer { ui.navigation = previous; ui.searchSpot = spot }
        let first = try XCTUnwrap(SettingsIndex.groups(alternateIcons: true).first)
        XCTAssertEqual(first, [.general, .search, .appearance, .appIcon, .tabs, .sync])
        XCTAssertFalse(SettingsIndex.groups(alternateIcons: false).joined().contains(.appIcon))
        XCTAssertEqual(SettingsIndex.macMark(.appIcon), "appIcon")
        XCTAssertNil(SettingsIndex.macTint(.appIcon), "a basic page: ink only")
        XCTAssertEqual(SettingsContent.title(.appIcon), "App Icon")
        let content = SettingsContent(store: .shared, context: SettingsContext(hasMac: false))
        XCTAssertFalse(content.sections(.appearance).flatMap(\.rows).contains { $0.id.contains("appIcon") })
        for query in ["app icon", "icon", "logo"] {
            XCTAssertTrue(SettingsIndex.matches(query, content: content).contains { $0.page == .appIcon }, query)
        }
        ui.openPage(.appIcon)
        XCTAssertEqual(ui.navigation.last, .page(.appIcon))
        XCTAssertEqual(UIApplication.shared.alternateIconName, actualName)
    }

    func testThemeNotesAndButtonWords() {
        XCTAssertEqual(PhoneAppIcon.flat.themeNote, "Follows Dark, Tinted and Clear")
        XCTAssertEqual(PhoneAppIcon.original.themeNote, "Follows Dark, Tinted and Clear")
        for icon in PhoneAppIcon.allCases where icon != .flat && icon != .original {
            XCTAssertEqual(icon.themeNote, "Dark and Tinted are made by iOS", icon.rawValue)
        }
        XCTAssertEqual(AppIconSelection.failure, "Couldn't change the icon. Try again.")
    }

    func testUnearnedRewardsStayLockedAndOnlyReferralArtworkCanBeBrowsed() throws {
        try withAccess { access, _ in
            for icon in PhoneAppIcon.allCases {
                if icon.isReward {
                    XCTAssertFalse(access.unlocked(icon), icon.rawValue)
                    XCTAssertEqual(access.visible(icon), icon.friendCount != nil || icon == .charm, icon.rawValue)
                } else if !icon.halloween {
                    XCTAssertTrue(access.unlocked(icon), icon.rawValue)
                    XCTAssertTrue(access.visible(icon), icon.rawValue)
                }
            }
            XCTAssertTrue(access.imported.isEmpty)
            XCTAssertTrue(access.kept.isEmpty)
        }
    }

    func testGrantSnapshotsReplacePreviousAccessAndRequireRealBooleansAndValidGiftReceipts() throws {
        try withAccess { access, defaults in
            let receipt = String(repeating: "a", count: 64)
            access.adopt([
                PhoneAppIcon.chrome.grantKey: .bool(true),
                PhoneAppIcon.amber.grantKey: .bool(false),
                PhoneAppIcon.redEnamel.grantKey: .string("true"),
                "appearance.appIcon.unlocked.unknown": .bool(true),
                "gift.firstEdition.receipt": .string(receipt),
            ])
            XCTAssertEqual(access.imported, [.chrome, .firstEdition])
            XCTAssertTrue(access.unlocked(.chrome))
            XCTAssertTrue(access.visible(.firstEdition))
            XCTAssertFalse(access.unlocked(.amber))
            XCTAssertFalse(access.unlocked(.redEnamel))
            XCTAssertTrue(access.kept.isEmpty, "account grants never become local ownership")
            XCTAssertNil(defaults.object(forKey: PhoneAppIcon.chrome.grantKey))
            XCTAssertNil(defaults.object(forKey: "gift.firstEdition.receipt"))

            for invalid in ["", "short", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
                access.adopt(["gift.firstEdition.receipt": .string(invalid)])
                XCTAssertTrue(access.imported.isEmpty, invalid)
                XCTAssertFalse(access.unlocked(.firstEdition), invalid)
            }
            access.adopt([PhoneAppIcon.ticket.grantKey: .bool(true)])
            XCTAssertEqual(access.imported, [.ticket])
            XCTAssertTrue(access.unlocked(.ticket))
            access.adopt([:])
            XCTAssertTrue(access.imported.isEmpty)
            XCTAssertFalse(access.unlocked(.ticket), "removing the account removes its grant")
        }
    }

    func testSeasonEndingKeepsOnlyWornArtworkAndPublishesOneGrant() throws {
        try withAccess { access, defaults in
            let end = PhoneAppIcon.halloweenEnd()
            let during = end.addingTimeInterval(-1)
            let seasonal = PhoneAppIcon.allCases.filter(\.halloween)
            for icon in seasonal {
                XCTAssertTrue(access.visible(icon, at: during), icon.rawValue)
                XCTAssertFalse(access.unlocked(icon, at: end), icon.rawValue)
            }
            XCTAssertTrue(access.kept.isEmpty, "looking at seasonal artwork never keeps it")

            var announced: [PhoneAppIcon] = []
            access.onKeep = { announced.append($0) }
            access.remember(.pumpkin, at: during)
            access.remember(.pumpkin, at: during)
            access.remember(.flat, at: during)
            access.remember(.ghost, at: end)
            XCTAssertEqual(announced, [.pumpkin])
            XCTAssertEqual(access.kept, [.pumpkin])
            for icon in seasonal {
                XCTAssertEqual(access.unlocked(icon, at: end), icon == .pumpkin, icon.rawValue)
                XCTAssertEqual(access.visible(icon, at: end), icon == .pumpkin, icon.rawValue)
            }
            let restored = AppIconAccess(defaults: defaults)
            XCTAssertTrue(restored.unlocked(.pumpkin, at: end))
            XCTAssertFalse(restored.unlocked(.ghost, at: end))
        }
    }

    func testAnInstalledLegacyRewardMigratesOnceWithoutKeepingLaterAccountChoices() throws {
        try withAccess { access, defaults in
            var published: [PhoneAppIcon] = []
            access.onKeep = { published.append($0) }
            access.keepLegacySelection(.chrome)
            access.keepLegacySelection(.chrome)
            access.keepLegacySelection(.firstEdition)
            access.keepLegacySelection(.flat)
            access.keepLegacySelection(nil)
            XCTAssertEqual(access.kept, [.chrome])
            XCTAssertTrue(access.unlocked(.chrome))
            XCTAssertFalse(access.unlocked(.amber))
            XCTAssertFalse(access.unlocked(.redEnamel))
            XCTAssertFalse(access.unlocked(.firstEdition))
            XCTAssertEqual(published, [.chrome], "the already installed legacy icon is a legitimate earned choice")
            access.adopt([PhoneAppIcon.amber.grantKey: .bool(true)])
            access.keepLegacySelection(.amber)
            access.adopt([:])
            let restored = AppIconAccess(defaults: defaults)
            XCTAssertTrue(restored.unlocked(.chrome))
            XCTAssertFalse(restored.unlocked(.amber), "an account grant does not leak into the kept local choice")
            XCTAssertEqual(published, [.chrome])
        }
    }

    func testAnInitiallyFreeNativeIconDoesNotTurnAFutureAccountRewardIntoLocalOwnership() throws {
        try withAccess { access, defaults in
            access.keepLegacySelection(.flat)
            access.adopt([PhoneAppIcon.redEnamel.grantKey: .bool(true)])
            access.keepLegacySelection(.redEnamel)
            access.adopt([:])
            XCTAssertTrue(access.kept.isEmpty)
            XCTAssertFalse(access.unlocked(.redEnamel))
            let restored = AppIconAccess(defaults: defaults)
            restored.keepLegacySelection(.redEnamel)
            XCTAssertFalse(restored.unlocked(.redEnamel), "the migration decision survives relaunch")
        }
    }

    func testEveryFriendColorPairHasFullResolutionArtworkAndAUniqueNativeAlternate() throws {
        let rightColors: [String?] = [nil] + PhoneAppIcon.charmColors.map { Optional($0) }
        var names: Set<String> = []
        for left in PhoneAppIcon.charmColors {
            for right in rightColors {
                let native = PhoneAppIcon.charmAlternateName(left: left, right: right)
                XCTAssertTrue(names.insert(native).inserted, "every pair needs its own native icon")
                let preview = PhoneAppIcon.charmPreviewName(left: left, right: right)
                XCTAssertEqual(PhoneAppIcon.installedCharmPreview(native), preview,
                               "About shows the installed pair while the gallery previews newly synced colors")
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let image = try XCTUnwrap(UIImage(named: preview, in: .main,
                                                     compatibleWith: UITraitCollection(userInterfaceStyle: style)), preview)
                    let pixels = try XCTUnwrap(image.cgImage)
                    XCTAssertEqual(pixels.width, 1024); XCTAssertEqual(pixels.height, 1024)
                }
            }
        }
        XCTAssertEqual(names.count, 56)
        XCTAssertEqual(names, Set(PhoneAppIcon.charmAlternates))
        XCTAssertEqual(PhoneAppIcon.charmAlternateName(left: "mint", right: nil), PhoneAppIcon.charm.alternateName)
    }

    func testBestFriendColorsFollowTheAccountWithoutUnlockingArtworkByThemselves() throws {
        try withAccess { access, _ in
            access.adopt(["invite.charm.left": .string("rose"), "invite.charm.right": .string("sky")])
            XCTAssertFalse(access.unlocked(.charm), "color data alone never grants Best Friends")
            access.adopt([
                PhoneAppIcon.charm.grantKey: .bool(true),
                "invite.charm.left": .string("rose"),
                "invite.charm.right": .string("sky"),
            ])
            XCTAssertTrue(access.unlocked(.charm))
            XCTAssertEqual(access.nativeName(for: .charm), PhoneAppIcon.charmAlternateName(left: "rose", right: "sky"))
            XCTAssertEqual(access.previewName(for: .charm), PhoneAppIcon.charmPreviewName(left: "rose", right: "sky"))
            access.adopt([:])
            XCTAssertFalse(access.unlocked(.charm))
            XCTAssertEqual(access.charmLeft, "mint")
            XCTAssertNil(access.charmRight)
            XCTAssertEqual(access.nativeName(for: .charm), "YabCharm")
            access.adopt(["invite.charm.left": .string("unknown"), "invite.charm.right": .string("unknown")])
            XCTAssertEqual(access.charmLeft, "mint")
            XCTAssertEqual(access.charmRight, "mint")
        }
    }

    /// Every policy test owns its defaults. UIKit's current icon and the
    /// test host's SettingsStore.shared are never changed by these fixtures.
    private func withAccess(_ body: (AppIconAccess, UserDefaults) throws -> Void) throws {
        let suite = "owned-app-icon-access-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(AppIconAccess(defaults: defaults), defaults)
    }
}
