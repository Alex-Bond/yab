import AppKit
import Testing
@testable import Fast

@MainActor
@Suite(.serialized)
struct AgentScreenshotTests {
    @Test func materialAppearingAfterAdmissionReleasesNoPixels() async throws {
        let page = await AgentKeysTests.page("<title>Account</title><h1>Ordinary account</h1>")
        var checks = 0
        do {
            _ = try await AgentImageGate.capture(page, shot: PageShot(width: 64)) {
                checks += 1
                let safe = (try? await page.call("return " + AgentSecrets.probe, in: .agent, gesture: false)) as? Bool == false
                if checks == 1 {
                    // The first admission was for an ordinary page. The
                    // pixels about to be captured now contain protected text.
                    _ = try? await page.call("document.body.innerHTML='<h1>Recovery phrase</h1><p>SYNTHETIC_WORDS_ONLY</p>'; return true;", in: .agent)
                }
                return safe
            }
            Issue.record("Protected pixels escaped the reply check")
        } catch {
            #expect(error is AgentSecrets.Refused)
        }
        #expect(checks == 2)
    }
}
