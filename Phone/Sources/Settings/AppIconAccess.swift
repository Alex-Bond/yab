import Foundation
import Observation
import SyncKit

/// Owned artwork follows the account; UIKit's selected icon stays local.
@MainActor
@Observable
final class AppIconAccess {
    private(set) var imported: Set<AppIconCatalog> = []
    private(set) var kept: Set<AppIconCatalog>
    private(set) var charmLeft = "mint"
    private(set) var charmRight: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored var onKeep: ((AppIconCatalog) -> Void)?
    private static let keptKey = "appearance.appIcons.kept"
    private static let migratedKey = "appearance.appIcons.migrated"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        kept = Set((defaults.stringArray(forKey: Self.keptKey) ?? []).compactMap(AppIconCatalog.init(rawValue:)))
    }

    func adopt(_ preferences: [String: Value]) {
        imported = Set(AppIconCatalog.allCases.filter { preferences[$0.grantKey]?.bool == true })
        let left = preferences["invite.charm.left"]?.string ?? "mint"
        charmLeft = AppIconCatalog.charmColors.contains(left) ? left : "mint"
        charmRight = preferences["invite.charm.right"]?.string.map { AppIconCatalog.charmColors.contains($0) ? $0 : "mint" }
        if AppIconCatalog.validReceipt(preferences["gift.firstEdition.receipt"]?.string) {
            imported.insert(.firstEdition)
        }
    }

    func unlocked(_ icon: AppIconCatalog, at date: Date = Date()) -> Bool {
        if imported.contains(icon) || kept.contains(icon) { return true }
        if icon.halloween { return AppIconCatalog.halloweenAvailable(at: date) }
        return !icon.isReward
    }

    func visible(_ icon: AppIconCatalog, at date: Date = Date()) -> Bool {
        if icon.friendCount != nil || icon == .charm { return true }
        return unlocked(icon, at: date)
    }

    func nativeName(for icon: AppIconCatalog) -> String? {
        icon == .charm ? AppIconCatalog.charmAlternateName(left: charmLeft, right: charmRight) : icon.alternateName
    }

    func previewName(for icon: AppIconCatalog) -> String {
        icon == .charm ? AppIconCatalog.charmPreviewName(left: charmLeft, right: charmRight) : icon.previewName
    }

    /// Only wearing a seasonal icon earns it. Browsing does not keep it.
    func remember(_ icon: AppIconCatalog, at date: Date = Date()) {
        guard icon.halloween, unlocked(icon, at: date), kept.insert(icon).inserted else { return }
        save()
        onKeep?(icon)
    }

    /// The three alternates were free in older iPhone builds. Keep the
    /// installed choice without granting the other two reward icons.
    func keepLegacySelection(_ icon: AppIconCatalog?) {
        guard !defaults.bool(forKey: Self.migratedKey) else { return }
        defaults.set(true, forKey: Self.migratedKey)
        guard let icon, [.chrome, .amber, .redEnamel].contains(icon), kept.insert(icon).inserted else { return }
        save()
        onKeep?(icon)
    }

    private func save() { defaults.set(kept.map(\.rawValue).sorted(), forKey: Self.keptKey) }
}
