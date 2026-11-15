import AppKit
@testable import Fast

/// Only tests that exercise an actual WK delegate/configuration may use this
/// contract. Their fixture must explicitly select .webKitOnly; there is no
/// engine substitution and they do not establish Chromium feature coverage.
@MainActor
func requireNativeWebKitFixture(_ tab: Fast.Tab, _ feature: String) -> PageView {
    guard tab.engineFactory.kinds == [.webKit], let view = tab.page.webKit else {
        preconditionFailure("Native WebKit fixture required for \(feature); selected \(tab.engineKind.rawValue)")
    }
    return view
}

extension PageHandle {
    /// The selected engine executes this expression; no WebKit fallback.
    @MainActor func fixtureExpression(_ code: String, world: PageWorld = .page) async throws -> Any? {
        try await evaluate(.expression(code), in: world, frame: nil, gesture: false)
    }
    @MainActor func fixtureFunction(_ code: String, arguments: [String: Any] = [:], world: PageWorld = .page) async throws -> Any? {
        try await evaluate(.function(code, arguments: arguments), in: world, frame: nil, gesture: false)
    }
}
