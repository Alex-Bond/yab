import AppKit

/// Body supplied by the script and frame identity supplied by the engine.
struct PageScriptMessage {
    let body: Any
    let frame: PageFrame
    weak var sourceView: NSView?
}

/// Existing relays retain their guards and main-actor handling in one place.
protocol PageScriptReceiving: AnyObject {
    func receive(_ message: PageScriptMessage)
}

/// A relay whose page awaits an answer: WebKit's replyHandler, or the
/// settled promise of Chromium's bridge (ChromiumScripts.receive).
protocol PageScriptReplying: AnyObject {
    func receive(_ message: PageScriptMessage, reply: @escaping @MainActor @Sendable (Any?, String?) -> Void)
}

/// An engine-neutral copy of the registration settings, in execution order.
struct PageScriptRegistration: Equatable {
    let source: String
    let world: PageWorld
    let atEnd: Bool
    let mainOnly: Bool
}
