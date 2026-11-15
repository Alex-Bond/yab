import AppKit
import Metal
import QuartzCore
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct DustLifetimeTests {
    private func until(_ check: () -> Bool, seconds: Double = 5) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !check(), Date() < end { try await Task.sleep(for: .milliseconds(20)) }
        #expect(check())
    }

    // Inspect only this process's private fixture object. This avoids any
    // production bench API or special behavior in the implementation.
    private func runs() -> [DustRun] {
        (Mirror(reflecting: Dust.shared).children.first { $0.label == "runs" }?.value as? [DustRun]) ?? []
    }
    private func link(_ run: DustRun) -> CAMetalDisplayLink? {
        guard let optional = Mirror(reflecting: run).children.first(where: { $0.label == "link" })?.value else { return nil }
        return Mirror(reflecting: optional).children.first?.value as? CAMetalDisplayLink
    }
    private func stored<T>(_ object: Any, _ name: String, as: T.Type) -> T? {
        guard let value = Mirror(reflecting: object).children.first(where: { $0.label == name })?.value else { return nil }
        return (value as? T) ?? (Mirror(reflecting: value).children.first?.value as? T)
    }
    private func thread(_ run: DustRun) -> Thread? {
        guard let optional = Mirror(reflecting: run).children.first(where: { $0.label == "thread" })?.value else { return nil }
        return Mirror(reflecting: optional).children.first?.value as? Thread
    }

    @Test func aStoppedOwnedDisplayLinkCannotKeepItsSnapshotAlive() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 260))
        view.wantsLayer = true
        window.contentView = view
        defer { window.close() }
        let root = try #require(view.layer)
        let text = CATextLayer()
        text.string = "Synthetic closed title"
        text.fontSize = 13
        text.foregroundColor = NSColor.black.cgColor
        text.contentsScale = 2
        text.frame = CGRect(x: 30, y: 110, width: 240, height: 28)
        root.addSublayer(text)
        window.contentView?.layoutSubtreeIfNeeded()
        Dust.shared.warm()
        try await until { Dust.shared.ready }
        #expect(runs().isEmpty)
        // First exercise the actual facade's registry ownership.
        try #require(Dust.shared.play(rows: [DustRow(rect: CGRect(x: 24, y: 110, width: 270, height: 28), start: 0, fold: 0)],
                                     host: view, over: view, renaming: true))
        let registered = try #require(runs().last)
        try await until { link(registered) != nil }
        // Stop callbacks without taking ownership of native invalidation.
        try #require(link(registered)).isPaused = true
        try await Task.sleep(for: .seconds(Rename.cross + 0.7))
        #expect(runs().isEmpty)

        // Direct real production runs let the fixture count completion,
        // independently of the facade removing an already-removed entry.
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pipeline = try #require(stored(Dust.shared, "pipeline", as: MTLRenderPipelineState.self))
        let queue = try #require(stored(Dust.shared, "queue", as: MTLCommandQueue.self))
        // Keep both paused-effect controls and the natural completion path.
        for (rename, paused) in [(true, true), (false, true), (false, false)] {
            let oldLayers = Set((root.sublayers ?? []).map(ObjectIdentifier.init))
            let row = DustRow(rect: CGRect(x: 24, y: 110, width: 270, height: 28), start: 0, fold: 0)
            let shot = try #require(Snapshot(host: view, rect: row.rect, rows: [row.rect], scale: 2))
            let run = try #require(DustRun(device: device, pipeline: pipeline, queue: queue, shot: shot,
                                           rows: [row], over: view, root: root, scale: 2, renaming: rename))
            var completions = 0
            run.start { completions += 1 }
            try await until { link(run) != nil }
            let owned = try #require(link(run))
            if paused { owned.isPaused = true }
            let ticking = try #require(thread(run))
            let overlays = (root.sublayers ?? []).filter { !oldLayers.contains(ObjectIdentifier($0)) }
            #expect(overlays.count == 1 && overlays.first is CAMetalLayer)
            try await Task.sleep(for: .seconds((rename ? Rename.cross : Dust.length) + 0.7))
            #expect(overlays.allSatisfy { $0.superlayer == nil })
            #expect(completions == 1)
            try await until { ticking.isFinished }
            // A later turn must not restore a layer or repeat completion.
            try await Task.sleep(for: .milliseconds(150))
            #expect(completions == 1 && text.superlayer === root)
        }
    }
}
