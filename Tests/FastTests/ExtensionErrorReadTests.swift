import Foundation
import Testing
import WebKit
@testable import Fast

/// Crash #61 (and #60): WebKit's extension NSErrors came back already freed,
/// and asking one for its `localizedDescription` crashed in objc_msgSend.
/// What Extensions.watch does when WebKit says a context's errors changed
/// never reads the context's `errors` and never asks an error for its text.
@MainActor
@Suite(.serialized)
struct ExtensionErrorReadTests {
    /// A live sentinel for every accessor seen on the dangling-error stacks.
    final class Tripwire: NSError, @unchecked Sendable {
        nonisolated(unsafe) static var asked = 0
        override var domain: String { Self.asked += 1; return "Tripwire" }
        override var code: Int { Self.asked += 1; return 7 }
        override var localizedDescription: String { Self.asked += 1; return "asked" }
        override var localizedFailureReason: String? { Self.asked += 1; return nil }
        override var userInfo: [String: Any] { Self.asked += 1; return [:] }
    }

    /// A context that counts reads of `errors`.
    final class Spy: WKWebExtensionContext {
        var errorsRead = 0
        override var errors: [any Swift.Error] {
            errorsRead += 1
            return [Tripwire(domain: WKWebExtensionContext.errorDomain, code: WKWebExtensionContext.Error.backgroundContentFailedToLoad.rawValue)]
        }
    }

    @MainActor final class Said { var failed = false }

    /// Whether checkWorker said it failed. A worker that failed to start
    /// never answers loadBackgroundContent: its silence is the failure.
    private func failed(_ context: Spy) async -> Bool {
        let said = Said()
        Extensions.checkWorker(context, within: .seconds(4)) { said.failed = true }
        for _ in 0..<60 where !said.failed { try? await Task.sleep(for: .milliseconds(100)) }
        return said.failed
    }

    /// One loaded by a controller of its own, with `worker` as its
    /// service worker's script, or none.
    private func spy(worker: String?) async throws -> (Spy, WKWebExtensionController, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-errors-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let background = worker != nil ? #","background":{"service_worker":"sw.js"}"# : ""
        try #"{"manifest_version":3,"name":"Errors test","version":"1.0"\#(background)}"#
            .write(to: folder.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try (worker ?? "").write(to: folder.appendingPathComponent("sw.js"), atomically: true, encoding: .utf8)
        let controller = WKWebExtensionController(configuration: .nonPersistent())
        let context = Spy(for: try await WKWebExtension(resourceBaseURL: folder))
        try controller.load(context)
        return (context, controller, folder)
    }

    @Test func aFailedWorkerIsFoundWithoutReadingErrors() async throws {
        let (context, controller, folder) = try await spy(worker: "this is not ( a script")
        defer { try? controller.unload(context); try? FileManager.default.removeItem(at: folder) }
        Tripwire.asked = 0
        #expect(await failed(context))
        #expect(context.errorsRead == 0)
        #expect(Tripwire.asked == 0)
    }

    @Test func aWorkingWorkerIsLeftAlone() async throws {
        let (context, controller, folder) = try await spy(worker: "self.started = true;")
        defer { try? controller.unload(context); try? FileManager.default.removeItem(at: folder) }
        #expect(await failed(context) == false)
        #expect(context.errorsRead == 0)
    }

    @Test func noWorkerIsNotWoken() async throws {
        let (context, controller, folder) = try await spy(worker: nil)
        defer { try? controller.unload(context); try? FileManager.default.removeItem(at: folder) }
        #expect(await failed(context) == false)
        #expect(context.errorsRead == 0)
    }

    /// A manifest error is just as unsafe as a context/runtime error. The
    /// previous fix only guarded the latter and still crashed in said(_:).
    final class ManifestSpy: WKWebExtension {
        var errorsRead = 0
        override var errors: [any Swift.Error] {
            errorsRead += 1
            return [Tripwire(domain: WKWebExtension.errorDomain, code: 7)]
        }
    }

    @Test func loadDoesNotReadManifestOrContextErrors() async throws {
        let (original, controller, folder) = try await spy(worker: nil)
        defer { try? controller.unload(original); try? FileManager.default.removeItem(at: folder) }
        let manifest = try await ManifestSpy(resourceBaseURL: folder)
        let context = Spy(for: manifest)
        Tripwire.asked = 0
        let lines = Extensions.read(errors: context)
        #expect(lines.isEmpty, "unsafe WebKit diagnostics must not be read at load")
        #expect(manifest.errorsRead == 0, "manifest errors must stay unread too")
        #expect(context.errorsRead == 0)
        #expect(Tripwire.asked == 0, "domain and code are unsafe as well as text")
    }
}
