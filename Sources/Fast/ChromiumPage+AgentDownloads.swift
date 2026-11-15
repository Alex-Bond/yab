import Foundation
import YabCoreClient

extension ChromiumPage {
    /// Use the page's native download manager and cookie context. Agent
    /// downloads must not acquire the person-initiated context-menu marker.
    func agentStartDownload(_ url: URL, allowed: @escaping () -> Bool, done: @escaping (Error?) -> Void) {
        Task { @MainActor in
            do {
                guard allowed() else { throw CancellationError() }
                let (core, id) = try await endpoint()
                guard allowed(), remoteID == id,
                      ChromiumProcess.shared.isCurrent(core) else { throw CancellationError() }
                _ = try await core.request("page.download", params: ["tab": .string(id), "url": .string(url.absoluteString)])
                done(nil)
            } catch {
                done(error)
            }
        }
    }
}
