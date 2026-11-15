import Foundation

/// Explicit platform metadata wins over legacy model names. Unknown peers never execute Mac work.
public enum SyncDevicePlatform: String, Codable, Sendable {
    case iOS = "ios", macOS = "macos", android, unknown

    public static var local: SyncDevicePlatform {
        #if os(iOS)
        return .iOS
        #else
        return .macOS
        #endif
    }

    public static func read(_ platform: String?, model: String) -> SyncDevicePlatform {
        if let platform, !platform.isEmpty { return SyncDevicePlatform(rawValue: platform) ?? .unknown }
        if model.hasPrefix("iPhone") || model.hasPrefix("iPad") || model.hasPrefix("iPod") { return .iOS }
        if model.hasPrefix("Mac") || model.hasPrefix("iMac") { return .macOS }
        return .unknown
    }

    public var isMobile: Bool { self == .iOS || self == .android }
}

/// A self-stamped command capability complements server admission and socket negotiation.
public enum AndroidSyncCompatibility {
    public static let version = 1
    public static let field = "androidSync"

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability, record.id == device, record.alive(),
              record["device"]?.string == device, record[field]?.number == Double(version),
              record.stamps[field]?.device == device, record.stamps["device"]?.device == device else { return false }
        return true
    }
}
