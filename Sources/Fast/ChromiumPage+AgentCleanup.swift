import Foundation

extension ChromiumPage {
    /// Isolated worlds cannot reliably traverse another document through
    /// contentDocument. Inspect each authenticated frame in its own world.
    /// Only a complete, unchanged inventory can say the tab has no draft.
    func agentCleanupBusy() async -> Bool? {
        do {
            let frames = try await agentFrames()
            let tokens = try Set(frames.compactMap { try scripts.token($0, tab: remoteID) })
            guard tokens.count == frames.count else { return nil }
            var uncertain = false
            for frame in frames {
                let value = try await run(PageScript.load("agent-cleanup"), in: .yab, frame: frame, gesture: false)
                if value as? Bool == true { return true }
                if value as? Bool != false { uncertain = true }
            }
            let current = try await agentFrames()
            let now = try Set(current.compactMap { try scripts.token($0, tab: remoteID) })
            guard current.count == now.count, now == tokens else { return nil }
            return uncertain ? nil : false
        } catch { return nil }
    }
}
