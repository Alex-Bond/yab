import AppKit
import Testing
import WebKit
@testable import Fast

@Suite(.serialized)
@MainActor
struct PageHandoffTests {
    @MainActor
    private final class HeldSnapshotWebView: WKWebView {
        private var snapshotCompletion: (@MainActor @Sendable (NSImage?, Error?) -> Void)?
        private(set) var snapshotRequests = 0
        var firstLoad = false
        override var isLoading: Bool { firstLoad || super.isLoading }

        nonisolated override func responds(to selector: Selector!) -> Bool {
            // Exercise the public snapshot fallback without invoking WebKit's
            // private presentation callback or depending on its timing.
            if selector == NSSelectorFromString("_doAfterNextPresentationUpdate:") { return false }
            return super.responds(to: selector)
        }

        override func takeSnapshot(with snapshotConfiguration: WKSnapshotConfiguration?,
                                   completionHandler: @escaping @MainActor @Sendable (NSImage?, Error?) -> Void) {
            snapshotRequests += 1
            snapshotCompletion = completionHandler
        }

        func deliverSnapshot() -> Bool {
            guard let completion = snapshotCompletion else { return false }
            snapshotCompletion = nil
            completion(NSImage(size: NSSize(width: 1, height: 1)), nil)
            return true
        }

        func discardSnapshot() { snapshotCompletion = nil }
    }

    @MainActor
    private struct Scene {
        let window: NSWindow
        let content: NSView
        let web: WKWebView

        init(web suppliedWeb: WKWebView? = nil) {
            _ = NSApplication.shared
            content = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
            window = NSWindow(contentRect: NSRect(x: -30000, y: 0, width: 700, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = content
            window.orderFront(nil)
            let holder = NSView(frame: content.bounds)
            content.addSubview(holder)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            web = suppliedWeb ?? WKWebView(frame: holder.bounds, configuration: configuration)
            web.frame = holder.bounds
            holder.addSubview(web)
        }

        func stage(owner: Tab.ID) -> StageView {
            let stage = StageView(frame: content.bounds)
            content.addSubview(stage)
            stage.show(web, of: owner)
            return stage
        }
    }

    private func waitUntil(timeout: TimeInterval = 2.5, _ condition: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while CACurrentMediaTime() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(condition())
    }

    @Test func aFreshPageKeepsTheDepartingSurfaceUntilItsDocumentPaints() {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let stage = scene.stage(owner: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coming = HeldSnapshotWebView(frame: stage.bounds, configuration: configuration)
        defer { coming.discardSnapshot() }
        coming.firstLoad = true
        let owner = UUID()
        stage.show(coming, of: owner)
        stage.show(coming, of: owner)
        #expect(scene.web.superview === stage)
        #expect(coming.layer?.opacity == 0)
        #expect(coming.snapshotRequests == 0)
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 1)
        #expect(coming.layer?.opacity == 0)
        #expect(coming.deliverSnapshot())
        #expect(coming.layer?.opacity == 1)
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 1)
    }

    @Test func aFreshPageThatNeverCommitsComesInAfterTheGroundWait() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let stage = scene.stage(owner: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coming = HeldSnapshotWebView(frame: stage.bounds, configuration: configuration)
        defer { coming.discardSnapshot() }
        coming.firstLoad = true
        let owner = UUID()
        let begun = CACurrentMediaTime()
        stage.show(coming, of: owner)
        #expect(coming.layer?.opacity == 0)
        // The departing page goes after paintWait, but an unpainted page
        // stays hidden over Yab's ground (#205), rather than showing white.
        try await waitUntil { scene.web.superview == nil }
        #expect(coming.layer?.opacity == 0)
        var ground = Palette.NS.ground.cgColor
        stage.effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.NS.ground.cgColor }
        #expect(stage.layer?.backgroundColor == ground)
        #expect(coming.snapshotRequests == 0)
        // A stopped load or download that never commits still has a bound.
        try await waitUntil(timeout: StageView.groundWait + 3) { coming.layer?.opacity == 1 }
        #expect(CACurrentMediaTime() - begun >= StageView.paintWait + StageView.groundWait - 0.1)
        #expect(stage.shows == owner)
        #expect(coming.snapshotRequests == 0)
        // Once that bound has expired, a late commit needs no new snapshot.
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 0)
    }

    @Test func aFreshPageCommittingAfterThePaintWaitRevealsOnlyAfterDrawing() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let stage = scene.stage(owner: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coming = HeldSnapshotWebView(frame: stage.bounds, configuration: configuration)
        defer { coming.discardSnapshot() }
        coming.firstLoad = true
        let owner = UUID()
        stage.show(coming, of: owner)
        try await waitUntil { scene.web.superview == nil }
        #expect(coming.layer?.opacity == 0)
        var ground = Palette.NS.ground.cgColor
        stage.effectiveAppearance.performAsCurrentDrawingAppearance { ground = Palette.NS.ground.cgColor }
        #expect(stage.layer?.backgroundColor == ground)
        #expect(coming.snapshotRequests == 0)
        // A commit inside groundWait asks for the first drawing. Its held
        // callback, rather than the commit alone, gives the page its opacity.
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 1)
        #expect(coming.layer?.opacity == 0)
        #expect(coming.deliverSnapshot())
        #expect(coming.layer?.opacity == 1)
        #expect(stage.shows == owner)
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 1)
    }

    @Test func aPageThatNeverPaintsComesInAfterTheWait() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let stage = scene.stage(owner: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coming = HeldSnapshotWebView(frame: stage.bounds, configuration: configuration)
        defer { coming.discardSnapshot() }
        coming.firstLoad = true
        stage.show(coming, of: UUID())
        stage.documentCommitted(coming)
        #expect(coming.snapshotRequests == 1)
        try await waitUntil(timeout: StageView.paintWait + StageView.groundWait + 3) { coming.layer?.opacity == 1 }
        // The paint arriving after the finite ground wait changes nothing.
        #expect(coming.deliverSnapshot())
        #expect(coming.layer?.opacity == 1)
    }

    @Test func aCancelledFirstDocumentCannotRevealAnotherOwnersPage() {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let stage = scene.stage(owner: UUID())
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let coming = HeldSnapshotWebView(frame: stage.bounds, configuration: configuration)
        coming.firstLoad = true
        stage.show(coming, of: UUID())
        let back = UUID()
        stage.show(scene.web, of: back)
        stage.documentCommitted(coming)
        #expect(stage.shows == back)
        #expect(scene.web.superview === stage)
        #expect(coming.layer?.opacity == 1)
        #expect(coming.snapshotRequests == 0)
    }

    @Test func anUnpresentedHandoffDeadlineCompletesFalseAndIgnoresLatePaint() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = HeldSnapshotWebView(frame: .zero, configuration: configuration)
        defer { web.discardSnapshot() }
        let scene = Scene(web: web)
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        _ = scene.stage(owner: owner)
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(web, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { _ in attachments += 1 },
                               done: { results.append($0) })

        try await waitUntil { web.snapshotRequests == 1 }
        #expect(attachments == 1)
        #expect(results.isEmpty)
        // No presentation receipt is delivered before the attached deadline.
        try await waitUntil { !results.isEmpty }
        #expect(results == [false])
        #expect(!cancelled)
        #expect(scene.window.isVisible)

        // A successful snapshot callback arriving after expiry is stale.
        #expect(web.deliverSnapshot())
        try await Task.sleep(for: .milliseconds(25))
        #expect(results == [false])
        #expect(attachments == 1)
        #expect(web.snapshotRequests == 1)
    }

    @Test func aPresentedHandoffCompletesTrueAndIgnoresItsLaterDeadline() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = HeldSnapshotWebView(frame: .zero, configuration: configuration)
        defer { web.discardSnapshot() }
        let scene = Scene(web: web)
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        _ = scene.stage(owner: owner)
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(web, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { _ in attachments += 1 },
                               done: { results.append($0) })

        try await waitUntil { web.snapshotRequests == 1 }
        #expect(attachments == 1)
        #expect(results.isEmpty)
        // Release after afterHandoff returns, ahead of its one-second bound.
        await Task.yield()
        #expect(web.deliverSnapshot())
        try await waitUntil { !results.isEmpty }
        #expect(results == [true])

        try await Task.sleep(for: .milliseconds(1150))
        #expect(results == [true])
        #expect(attachments == 1)
        #expect(web.snapshotRequests == 1)
    }

    @Test func aSlowReceivingStageCannotReleaseThePageEarly() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(scene.web, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { stage in
            attachments += 1
            #expect(stage.shows == owner)
            #expect(scene.web.superview === stage)
            #expect(scene.web.frame.size == stage.bounds.size)
        }, done: { results.append($0) })

        // SwiftUI can attach after the former unconditional timeout.
        try await Task.sleep(for: .milliseconds(1150))
        #expect(attachments == 0)
        #expect(results.isEmpty)

        let stage = scene.stage(owner: owner)
        try await waitUntil { !results.isEmpty }
        #expect(attachments == 1)
        #expect(results == [true])
        #expect(scene.web.superview === stage)
    }

    @Test func anotherOwnerCannotCompleteTheHandoff() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        let stage = scene.stage(owner: UUID())
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(scene.web, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { _ in attachments += 1 },
                               done: { results.append($0) })

        try await Task.sleep(for: .milliseconds(1150))
        #expect(attachments == 0)
        #expect(results.isEmpty)

        stage.show(scene.web, of: owner)
        try await waitUntil { !results.isEmpty }
        #expect(attachments == 1)
        #expect(results == [true])
    }

    @Test func anotherWindowCannotCompleteTheHandoff() async throws {
        let source = Scene()
        let destination = Scene()
        defer {
            source.window.orderOut(nil)
            destination.window.orderOut(nil)
        }
        let owner = UUID()
        let sourceStage = source.stage(owner: owner)
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(source.web, owner: owner, window: { destination.window },
                               cancelled: { cancelled }, attached: { stage in
            attachments += 1
            #expect(stage.window === destination.window)
        }, done: { results.append($0) })

        try await Task.sleep(for: .milliseconds(1150))
        #expect(attachments == 0)
        #expect(results.isEmpty)

        sourceStage.away = true
        let stage = StageView(frame: destination.content.bounds)
        destination.content.addSubview(stage)
        stage.show(source.web, of: owner)
        try await waitUntil { !results.isEmpty }
        #expect(attachments == 1)
        #expect(results == [true])
        #expect(source.web.superview === stage)
    }

    @Test(arguments: [false, true])
    func cancellationCompletesOnce(waitingForPresentation: Bool) async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        if waitingForPresentation { _ = scene.stage(owner: owner) }
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(scene.web, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { _ in
            attachments += 1
            cancelled = true
        }, done: { results.append($0) })
        cancelled = true

        try await waitUntil { !results.isEmpty }
        #expect(results == [false])
        #expect(attachments == (waitingForPresentation ? 1 : 0))
        // A presentation callback and the post-attachment fallback can race.
        try await Task.sleep(for: .milliseconds(1150))
        #expect(results == [false])
    }

    @Test(arguments: [false, true])
    func hidingTheDestinationCompletesOnce(waitingForPresentation: Bool) async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        if waitingForPresentation { _ = scene.stage(owner: owner) }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(scene.web, owner: owner, window: { scene.window },
                               cancelled: { false }, attached: { _ in
            attachments += 1
            // Hide before WebKit can return its presentation callback.
            scene.window.orderOut(nil)
        }, done: { results.append($0) })
        if !waitingForPresentation { scene.window.orderOut(nil) }

        try await waitUntil { !results.isEmpty }
        #expect(results == [false])
        #expect(attachments == (waitingForPresentation ? 1 : 0))

        // Reopening that window cannot resurrect its completed transfer.
        scene.window.orderFront(nil)
        if !waitingForPresentation { _ = scene.stage(owner: owner) }
        try await Task.sleep(for: .milliseconds(1150))
        #expect(results == [false])
        #expect(attachments == (waitingForPresentation ? 1 : 0))
    }

    @Test func anInitiallyMissingDestinationCanAppearLater() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        let owner = UUID()
        let stage = scene.stage(owner: owner)
        var destination: NSWindow?
        var cancelled = false
        defer { cancelled = true }
        var attachments = 0
        var results: [Bool] = []
        StageView.afterHandoff(scene.web, owner: owner, window: { destination },
                               cancelled: { cancelled }, attached: { _ in attachments += 1 },
                               done: { results.append($0) })

        try await Task.sleep(for: .milliseconds(1150))
        #expect(attachments == 0)
        #expect(results.isEmpty)

        destination = scene.window
        try await waitUntil { !results.isEmpty }
        #expect(attachments == 1)
        #expect(results == [true])
        #expect(scene.web.superview === stage)
    }

    @Test func movingTheLoadedWebViewKeepsItsDocumentAndInteractionState() async throws {
        let scene = Scene()
        defer { scene.window.orderOut(nil) }
        scene.web.loadHTMLString("""
        <!doctype html><html><body style="margin:0; height:4000px; background:#2468ad">
        <input id="draft"><script>window.initialDocument = document;</script>
        </body></html>
        """, baseURL: URL(string: "https://handoff.test/"))
        var loaded = false
        for _ in 0..<200 {
            loaded = (try? await scene.web.evaluateJavaScript("document.readyState === 'complete' && !!document.getElementById('draft')")) as? Bool == true
            if loaded, !scene.web.isLoading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(loaded)
        _ = try await scene.web.evaluateJavaScript("""
        window.interactionState = { count: 7 };
        document.getElementById('draft').value = 'unsent draft';
        window.scrollTo(0, 480);
        """)
        #expect(try await scene.web.evaluateJavaScript("window.scrollY") as? Int == 480)

        let owner = UUID()
        let existingWeb = scene.web
        var cancelled = false
        defer { cancelled = true }
        var results: [Bool] = []
        StageView.afterHandoff(existingWeb, owner: owner, window: { scene.window },
                               cancelled: { cancelled }, attached: { _ in },
                               done: { results.append($0) })
        let stage = scene.stage(owner: owner)
        try await waitUntil { !results.isEmpty }

        #expect(results == [true])
        #expect(existingWeb.superview === stage)
        #expect(stage.subviews.contains { $0 === existingWeb })
        #expect(try await existingWeb.evaluateJavaScript("window.initialDocument === document") as? Bool == true)
        #expect(try await existingWeb.evaluateJavaScript("window.interactionState.count") as? Int == 7)
        #expect(try await existingWeb.evaluateJavaScript("document.getElementById('draft').value") as? String == "unsent draft")
        #expect(try await existingWeb.evaluateJavaScript("window.scrollY") as? Int == 480)
    }
}
