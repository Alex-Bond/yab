import Foundation

/// Chat-list choices go to the Mac only when it understands their stamps.
public enum ChatMetadata {
    public static let version = 1

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record["chatMetadata"]?.number == Double(version)
    }
}

/// Stop and Delete for a chat from the iPhone (SyncSend.action): a phone
/// offers them only to a Mac that names this version in its `commandcap`
/// as `chatControl`; an older Mac would take the empty words for a turn.
public enum ChatControl {
    public static let version = 1

    public static func supports(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability,
              record.id == device, record.alive(), record["device"]?.string == device else { return false }
        return record["chatControl"]?.number == Double(version)
    }
}
