// Unused IO surfaces required to typecheck production TaskRecords/OpenOnMac.
// Every wire model, URL validation, digest and encoder comes from production sources.
import Foundation
public final class Journal {
    public var clock: Clock { fatalError("Oracle never opens a journal clock") }
    public func record(_ key: Record.Key) -> Record? { fatalError("Oracle never opens a journal") }
    @discardableResult public func change(_ key: Record.Key, _ fields: [String: Value]) throws -> Record { fatalError("Oracle never writes a journal") }
    public func claimCommand(_ record: Record, fields: [String: Value]) throws -> Bool { fatalError("Oracle never consumes a command") }
}
public final class SyncClient {
    public enum State: Equatable { case live }
    public struct Listed { public var id: String; public var revoked: Bool; public var isMobile: Bool }
    public struct Device { public var id: String }
    public var state: State { .live }
    public var device: Device { fatalError("Oracle never owns a device") }
    public var seal: Seal { fatalError("Oracle never publishes") }
    public var journal: Journal { fatalError("Oracle never opens a journal") }
    public func kick() { fatalError("Oracle never sends") }
    public func kick(alerting key: Record.Key, withdraw: Bool = false) { fatalError("Oracle never sends an alert") }
}
