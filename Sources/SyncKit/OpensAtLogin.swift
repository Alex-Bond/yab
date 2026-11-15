import Foundation

/// Whether a Mac opens Yab when its person logs in (Settings › General,
/// Open at Login, its window put away), as it says in its `commandcap`
/// record. An iPhone says Yab "starts hidden when you log in" only for a
/// Mac that says so; for any other it says how to turn it on.
public enum OpensAtLogin {
    public static let field = "atLogin"

    public static func value(_ on: Bool) -> Value { on ? .bool(true) : .null }

    public static func reads(_ record: Record?, device: String) -> Bool {
        guard let record, record.collection == OpenOnMac.capability, record.id == device,
              record.alive(), record["device"]?.string == device else { return false }
        return record[field]?.bool == true
    }
}
