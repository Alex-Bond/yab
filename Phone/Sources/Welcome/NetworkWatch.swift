import Foundation
import Network
import Observation

/// Whether this iPhone is online, as the welcome needs to know before it
/// offers to join a Mac. Watching the path asks nothing of the person.
@MainActor
@Observable
final class NetworkWatch {
    static let shared = NetworkWatch()

    private(set) var online = true
    /// Named states: offline (or online) whatever the network says.
    var forcedOffline: Bool?

    var isOnline: Bool { forcedOffline.map { !$0 } ?? online }

    @ObservationIgnored private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.online != online else { return }
                self.online = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "dev.serafim.fast.iphone.network", qos: .utility))
    }
}
