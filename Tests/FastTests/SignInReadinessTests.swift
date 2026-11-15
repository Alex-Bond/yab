import Testing
@testable import Fast

@MainActor
struct SignInReadinessTests {
    @Test func concurrentPagesWaitForOnePreparation() {
        let gate = SignInReadiness()
        var starts = 0
        var finish: (@MainActor () -> Void)?
        var pages: [Int] = []
        for page in 0..<3 {
            gate.whenReady(prepare: { ready in starts += 1; finish = ready }, done: { pages.append(page) })
        }
        #expect(starts == 1)
        #expect(pages.isEmpty)
        finish?()
        #expect(pages == [0, 1, 2])
        finish?()
        #expect(pages == [0, 1, 2])
        gate.whenReady(prepare: { _ in starts += 1 }, done: { pages.append(3) })
        #expect(starts == 1)
        #expect(pages == [0, 1, 2, 3])
    }

    @Test(arguments: [false, true])
    func pagesWaitForPolicyAndLaunchCookies(cookiesFirst: Bool) {
        let cookies = SignInReadiness()
        let policy = SignInReadiness()
        var finishCookies: (@MainActor () -> Void)?
        var finishPolicy: (@MainActor () -> Void)?
        var restored = 0
        var configured = 0
        var requests = 0
        let restore: (@escaping @MainActor () -> Void) -> Void = { ready in
            restored += 1
            finishCookies = ready
        }
        // Launch can start restoration before the first tab is made.
        cookies.whenReady(prepare: restore, done: {})
        for _ in 0..<2 {
            policy.whenReady(prepare: { ready in configured += 1; finishPolicy = ready }, done: {
                cookies.whenReady(prepare: restore, done: { requests += 1 })
            })
        }
        #expect(requests == 0)
        if cookiesFirst { finishCookies?() } else { finishPolicy?() }
        #expect(requests == 0)
        if cookiesFirst { finishPolicy?() } else { finishCookies?() }
        #expect(requests == 2)
        #expect(restored == 1)
        #expect(configured == 1)
    }

    @Test func aPageCanStartRestorationBeforeTheLaunchHook() {
        let policy = SignInReadiness()
        let cookies = SignInReadiness()
        var finish: (@MainActor () -> Void)?
        var requested = false
        policy.whenReady(prepare: { $0() }, done: {
            cookies.whenReady(prepare: { finish = $0 }, done: { requested = true })
        })
        #expect(finish != nil)
        #expect(!requested)
        cookies.whenReady(prepare: { _ in Issue.record("Launch restored cookies twice") }, done: {})
        finish?()
        #expect(requested)
    }

    @Test func aLaterStoreWaitsForItsOwnPolicy() {
        let cookies = SignInReadiness()
        cookies.whenReady(prepare: { $0() }, done: {})
        let first = SignInReadiness()
        first.whenReady(prepare: { $0() }, done: {})
        let other = SignInReadiness()
        var finish: (@MainActor () -> Void)?
        var requested = false
        other.whenReady(prepare: { finish = $0 }, done: {
            cookies.whenReady(prepare: { _ in Issue.record("Cookies restored twice") }, done: { requested = true })
        })
        #expect(!requested)
        finish?()
        #expect(requested)
    }

    @Test func emptyPreparationAndReentrantPagesFinishSynchronously() {
        let gate = SignInReadiness()
        var requests = 0
        gate.whenReady(prepare: { $0() }, done: {
            requests += 1
            gate.whenReady(prepare: { _ in Issue.record("Preparation started twice") }, done: { requests += 1 })
        })
        #expect(requests == 2)
    }

    @Test func pagesGoOnWhenPreparationNeverReplies() async throws {
        let gate = SignInReadiness(deadline: 0.05)
        var pages: [Int] = []
        var finish: (@MainActor () -> Void)?
        gate.whenReady(prepare: { finish = $0 }, done: { pages.append(0) })
        gate.whenReady(prepare: { _ in Issue.record("Preparation started twice") }, done: { pages.append(1) })
        #expect(pages.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pages == [0, 1])
        finish?()
        #expect(pages == [0, 1])
    }
}
