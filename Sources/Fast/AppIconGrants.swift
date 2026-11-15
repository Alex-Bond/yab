import Foundation
import SyncKit

/// Permanent icon awards, as read from this Mac's existing receipts and
/// the account's independent grants. Seasonal availability never awards one.
enum AppIconGrants {
    static func icon(for key: String) -> AppIconCatalog? {
        guard key.hasPrefix(AppIconCatalog.grantPrefix) else { return nil }
        return AppIconCatalog(rawValue: String(key.dropFirst(AppIconCatalog.grantPrefix.count)))
    }

    /// A synced charm grant carries ownership, but this installation's
    /// relationship alone may publish the halves' colors.
    static func ownsLocalCharm(_ defaults: [String: Any]) -> Bool {
        if let data = defaults["invite.received"] as? Data,
           let received = try? JSONDecoder().decode(Received.self, from: data), received.best {
            return true
        }
        if let data = defaults["invite.best"] as? Data,
           let best = try? JSONDecoder().decode(Best.self, from: data), best.joined {
            return true
        }
        return false
    }

    static func owned(_ defaults: [String: Any]) -> Set<AppIconCatalog> {
        var owned = Set(AppIconCatalog.allCases.filter { defaults[$0.grantKey] as? Bool == true })
        let joined = (defaults["invite.joined"] as? NSNumber)?.intValue ?? 0
        for icon in AppIconCatalog.allCases {
            if let count = icon.friendCount, joined >= count { owned.insert(icon) }
        }
        if let data = defaults["invite.received"] as? Data,
           (try? JSONDecoder().decode(Received.self, from: data)) != nil {
            owned.insert(.waxSeal)
        }
        if ownsLocalCharm(defaults) { owned.insert(.charm) }
        let postIcons: Set<AppIconCatalog> = [.chrome, .amber, .redEnamel]
        if let data = defaults["invite.posts"] as? Data {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for post in (try? decoder.decode([Post].self, from: data)) ?? [] {
                if let icon = post.reward.flatMap(AppIconCatalog.init(rawValue:)), postIcons.contains(icon) {
                    owned.insert(icon)
                }
            }
        }
        if let kept = defaults["invite.post.kept"] as? String,
           let icon = AppIconCatalog(rawValue: kept), postIcons.contains(icon) {
            owned.insert(icon)
        }
        if defaults["wrapped.finished"] as? Bool == true { owned.insert(.arcade) }
        if AppIconCatalog.validReceipt(defaults["gift.firstEdition.receipt"] as? String) { owned.insert(.firstEdition) }
        for rawValue in defaults["halloween.worn"] as? [String] ?? [] {
            if let icon = AppIconCatalog(rawValue: rawValue), icon.halloween { owned.insert(icon) }
        }
        return owned
    }

    private struct Received: Decodable {
        let from: String
        let best: Bool
        let color: String?
    }

    private struct Best: Decodable {
        let name: String
        let color: String?
        let joined: Bool
    }

    private struct Post: Decodable {
        let url: String
        let state: String
        let posted: Date
        let reward: String?
        let opens: Date?
    }
}
