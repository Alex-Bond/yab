import Foundation
import Testing
@testable import Fast

/// #588: a slow Security.framework dependency must leave the UI's queue free.
/// Uses no real keychain item, credentials, account or system permission.
@MainActor
struct PlanKeychainTests {
    @Test func aStalledKeychainReadLetsTheMainQueueRespond() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("yab-keychain-delay-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        final class Observation: @unchecked Sendable {
            let lock = NSLock()
            var onMain = true
            var responded = false
        }
        let observation = Observation()
        let pulse = DispatchSemaphore(value: 0)
        let who = await PlanAccounts.read("claude", env: ["CLAUDE_CONFIG_DIR": home.path], keychain: { _ in
            let onMain = Thread.isMainThread
            DispatchQueue.main.async { pulse.signal() }
            // On main this deliberately times out; off main the UI queue
            // can service its pending event while Security is still busy.
            let responded = pulse.wait(timeout: .now() + 1) == .success
            observation.lock.withLock {
                observation.onMain = onMain
                observation.responded = responded
            }
            return true
        })
        #expect(who.signedIn)
        let (onMain, responded) = observation.lock.withLock { (observation.onMain, observation.responded) }
        #expect(!onMain, "The keychain dependency must run off the main thread")
        #expect(responded, "The main queue must respond before the blocked keychain dependency returns")
    }
}
