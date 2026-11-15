import Foundation
import YabCoreClient

/// A document and DevTools must both exist before script dispatch. CEF's
/// HasDocument can become false after pushState; a native default main-frame
/// context also proves the document exists. No request is retried here.
@MainActor
enum Seam2Ready {
    static func wait(timeout: Duration = .seconds(15),
                     state: @MainActor () async throws -> JSONValue) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            let value = try await state()
            try Task.checkCancellation()
            let document = value["hasDocument"] == .bool(true) || value["hasMainContext"] == .bool(true)
            if document, value["devToolsReady"] == .bool(true) { return }
            guard clock.now < deadline else { throw YabCoreError.timeout }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
