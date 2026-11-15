import AppKit
import Network

struct LoadNetworkPath {
    private var reachable: Bool?
    mutating func update(available: Bool) -> Bool {
        let restored = reachable == false && available
        reachable = available
        return restored
    }
}

/// One path observer for WebKit pages. Weak owners cannot retain closed tabs.
@MainActor
final class LoadNetwork {
    static let shared = LoadNetwork()
    private let monitor = NWPathMonitor()
    private let pages = NSHashTable<WebKitPageEvents>.weakObjects()
    private var path = LoadNetworkPath()
    private var observations: [NSObjectProtocol] = []

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(available: available) }
        }
        monitor.start(queue: DispatchQueue(label: "yab.load-network"))
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didUnhideNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pages.allObjects.forEach { $0.resumeNetworkLoad() } }
            })
        }
    }

    func watch(_ page: WebKitPageEvents) { pages.add(page) }

    private func pathChanged(available: Bool) {
        let restored = path.update(available: available)
        if !available {
            for page in pages.allObjects { page.networkUnavailable() }
            return
        }
        guard restored else { return }
        for page in pages.allObjects { page.networkRestored() }
    }
}
