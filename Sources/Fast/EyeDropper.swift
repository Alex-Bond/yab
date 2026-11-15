import AppKit
import WebKit

// The web's EyeDropper, which Chrome has and WebKit doesn't (row 1074).
//
// `new EyeDropper().open()` shows a magnifier under the pointer and gives
// the color clicked, anywhere on the screen. Color picker sites call it,
// and so do color picker extensions: ColorZilla offers "Pick Color From
// Outside the Browser" only where `'EyeDropper' in window`, and others
// have nothing else. Here it is the Mac's own color sampler
// (NSColorSampler), the magnifier the system color panel's dropper shows.
//
// A page gets it from eyedropper-page.js in its own world, through
// eyedropper-bridge.js in Yab's (EyeDropperRelay); an extension's own
// pages, its popup above all, from extension-shims.js, through the
// shim's native messages ("eyedropper.open", ExtensionShims). Both end
// here, one sampler at a time.

@MainActor
enum EyeDropperSampler {
    /// What a page that asked is told: the color, or why not.
    enum Answer {
        case color(String)
        case canceled
        case busy
    }

    private static var sampler: NSColorSampler?
    /// The page's request the sampler is up for, so a page that gives up
    /// (its signal) can be told apart from the one that comes after.
    private static var current: String?
    private static var waiting: ((Answer) -> Void)?

    /// Test runs: the sampler isn't shown, the bench answers it (`eyedropper`).
    static var standIn = false
    static var isOpen: Bool { waiting != nil }

    static func pick(_ request: String = UUID().uuidString) async -> Answer {
        await withCheckedContinuation { continuation in
            open(request) { continuation.resume(returning: $0) }
        }
    }

    static func open(_ request: String, _ done: @escaping (Answer) -> Void) {
        guard waiting == nil else { return done(.busy) }
        current = request
        waiting = done
        if Store.testing && standIn { return }
        let sampler = NSColorSampler()
        self.sampler = sampler
        sampler.show { color in
            let picked = color.flatMap { hex($0) }
            Task { @MainActor in
                guard self.sampler === sampler else { return }
                finish(picked.map(Answer.color) ?? .canceled)
            }
        }
    }

    /// The page stopped waiting (its signal): the sampler can't be taken
    /// down, so its answer, when it comes, goes nowhere.
    static func cancel(_ request: String) {
        guard current == request else { return }
        current = nil
        waiting = nil
    }

    /// The bench's answer to a stand-in sampler: a color, or nil for Escape.
    static func answer(_ hex: String?) -> Bool {
        guard waiting != nil else { return false }
        finish(hex.flatMap { NSColor(hex: $0) }.flatMap(Self.hex).map(Answer.color) ?? .canceled)
        return true
    }

    private static func finish(_ answer: Answer) {
        let done = waiting
        sampler = nil
        current = nil
        waiting = nil
        done?(answer)
    }

    /// "#rrggbb", lower case, in sRGB, as the EyeDropper API gives it.
    static func hex(_ color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        let part = { (v: CGFloat) in String(format: "%02x", Int((min(1, max(0, v)) * 255).rounded())) }
        return "#" + part(rgb.redComponent) + part(rgb.greenComponent) + part(rgb.blueComponent)
    }
}

/// A page's EyeDropper, from Yab's world (eyedropper-bridge.js).
final class EyeDropperRelay: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "yabEyeDropper"
    static let shared = EyeDropperRelay()
    static let asked = "yab-eyedropper-ask"
    static let answered = "yab-eyedropper-answer"
    static let page = PageScript.load("eyedropper-page", vars: ["ASKED": asked, "ANSWERED": answered])
    static let bridge = PageScript.load("eyedropper-bridge", vars: ["NAME": name, "ASKED": asked, "ANSWERED": answered])

    /// An extension's own pages, its popup above all (ColorZilla's "Pick
    /// Color From Outside the Browser"), on the controller they share. Its
    /// own name: a tab showing one of those pages puts a tab's handlers on
    /// the same controller, and a name taken twice raises. In the page's
    /// world, as Passkeys' is, the extension's page being the extension's.
    static let extensionName = "yabExtensionEyeDropper"
    nonisolated(unsafe) private static var relayKey: UInt8 = 0
    @MainActor private static let extensionScripts = [
        page, PageScript.load("eyedropper-bridge", vars: ["NAME": extensionName, "ASKED": asked, "ANSWERED": answered]),
    ].map { WKUserScript(source: $0, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page) }

    /// Again as a popup or a window of the extension's opens: a tab showing
    /// one of its pages puts its own scripts in place of everything there
    /// (PageScripts.fit).
    @MainActor static func install(in controller: WKUserContentController) {
        if objc_getAssociatedObject(controller, &relayKey) == nil {
            controller.addScriptMessageHandler(shared, contentWorld: .page, name: extensionName)
            objc_setAssociatedObject(controller, &relayKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let have = Set(controller.userScripts.map(ObjectIdentifier.init))
        for script in extensionScripts where !have.contains(ObjectIdentifier(script)) { controller.addUserScript(script) }
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String,
                  let id = body["id"] as? String, !id.isEmpty, id.count < 64
            else { return replyHandler(nil, "Not a request") }
            let request = id
            switch kind {
            case "cancel":
                EyeDropperSampler.cancel(request)
                replyHandler(NSNull(), nil)
            case "open":
                // Only a page that can be seen: a tab in front, in a window
                // on screen. Another tab's gesture can't open it over this one.
                guard let web = message.webView, let window = web.window, window.isVisible, !web.isHiddenOrHasHiddenAncestor else {
                    return replyHandler(["error": "NotAllowedError", "message": "The page isn't in front."], nil)
                }
                // A popup closes as the sampler takes the pointer, and the
                // color would have nowhere to go: held open until it comes.
                let popup = ExtensionPopup.hold(web)
                EyeDropperSampler.open(request) { answer in
                    popup?()
                    switch answer {
                    case .color(let hex): replyHandler(["hex": hex], nil)
                    case .canceled: replyHandler(["error": "AbortError", "message": "The user canceled the selection."], nil)
                    case .busy: replyHandler(["error": "InvalidStateError", "message": "An eye dropper is already open."], nil)
                    }
                }
            default:
                replyHandler(nil, "Not a request")
            }
        }
    }
}
