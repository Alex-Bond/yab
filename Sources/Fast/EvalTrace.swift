import AppKit
import WebKit

/// Every script Yab runs in a page, and every press of the left button, as
/// lines on standard error, with YAB_EVAL_TRACE set (evals/activation).
/// A script WebKit runs for the app is a user gesture, and on macOS 27's
/// WebKit (bug 324512) its end takes the page's transient activation with
/// it: one that lands between a click's mouse-down and its click event, or
/// in the seconds a page may still act on the click, leaves the page's copy
/// button, popup or permission ask with no click behind it. The lines say
/// which of Yab's scripts ran when:
///
///     EVAL-TRACE {"t": ms since 1970, "kind": "eval"|"done"|"down"|"up", ...}
///
/// Otherwise nothing.
enum EvalTrace {
    static let on = ProcessInfo.processInfo.environment["YAB_EVAL_TRACE"] != nil

    private nonisolated(unsafe) static var serial = 0
    private nonisolated(unsafe) static var depth = 0

    static func install() {
        guard on else { return }
        var count: UInt32 = 0
        if let list = class_copyMethodList(WKWebView.self, &count) {
            let names = (0..<Int(count)).map { NSStringFromSelector(method_getName(list[$0])) }.filter { $0.contains("JavaScript") }
            free(list)
            line(["kind": "methods", "names": names.sorted()])
        }
        typealias Done = @convention(block) (AnyObject?, NSError?) -> Void

        // evaluateJavaScript:completionHandler:
        swap("evaluateJavaScript:completionHandler:") { (old: IMP, selector: Selector) in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, Done?) -> Void = { web, script, done in
                let id = begin(web, script, via: "evaluateJavaScript", gesture: true, world: "page")
                call(web, selector, script, finish(id, done))
                depth -= 1
            }
            return imp_implementationWithBlock(block)
        }
        // evaluateJavaScript:inFrame:inContentWorld:completionHandler:
        swap("evaluateJavaScript:inFrame:inContentWorld:completionHandler:") { old, selector in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, WKFrameInfo?, WKContentWorld, Done?) -> Void = { web, script, frame, world, done in
                let id = begin(web, script, via: "evaluateJavaScript:in:", gesture: true, world: world.name ?? "page", frame: frame)
                call(web, selector, script, frame, world, finish(id, done))
                depth -= 1
            }
            return imp_implementationWithBlock(block)
        }
        // callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:
        swap("callAsyncJavaScript:arguments:inFrame:inContentWorld:completionHandler:") { old, selector in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, NSDictionary?, WKFrameInfo?, WKContentWorld, Done?) -> Void = { web, script, arguments, frame, world, done in
                let id = begin(web, script, via: "callAsyncJavaScript", gesture: true, world: world.name ?? "page", frame: frame)
                call(web, selector, script, arguments, frame, world, finish(id, done))
                depth -= 1
            }
            return imp_implementationWithBlock(block)
        }
        // The private road the public ones take, and QuietScript's: only a
        // call made straight to it is a line of its own.
        swap("_evaluateJavaScript:asAsyncFunction:withSourceURL:withArguments:forceUserGesture:inFrame:inWorld:completionHandler:") { old, selector in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, Bool, NSURL?, NSDictionary?, Bool, WKFrameInfo?, WKContentWorld, Done?) -> Void = {
                web, script, async, source, arguments, gesture, frame, world, done in
                let id = begin(web, script, via: "_evaluateJavaScript", gesture: gesture, world: world.name ?? "page", frame: frame)
                call(web, selector, script, async, source, arguments, gesture, frame, world, finish(id, done))
                depth -= 1
            }
            return imp_implementationWithBlock(block)
        }
        // The page's world with no gesture.
        swap("_evaluateJavaScriptWithoutUserGesture:completionHandler:") { old, selector in
            typealias Call = @convention(c) (AnyObject, Selector, NSString, Done?) -> Void
            let call = unsafeBitCast(old, to: Call.self)
            let block: @convention(block) (AnyObject, NSString, Done?) -> Void = { web, script, done in
                let id = begin(web, script, via: "withoutUserGesture", gesture: false, world: "page")
                call(web, selector, script, finish(id, done))
                depth -= 1
            }
            return imp_implementationWithBlock(block)
        }

        _ = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            let target = event.window?.contentView?.hitTest(event.locationInWindow).map { "\(type(of: $0))" } ?? ""
            line(["kind": event.type == .leftMouseDown ? "down" : "up", "clicks": event.clickCount, "view": target,
                  "uptime": event.timestamp * 1000])
            return event
        }
    }

    private static func swap(_ name: String, _ make: (IMP, Selector) -> IMP) {
        let selector = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(WKWebView.self, selector) else {
            line(["kind": "missing", "selector": name])
            return
        }
        method_setImplementation(method, make(method_getImplementation(method), selector))
    }

    /// The call, once: a public method that calls another is one script.
    private static func begin(_ web: AnyObject, _ script: NSString, via: String, gesture: Bool, world: String, frame: WKFrameInfo? = nil) -> Int? {
        depth += 1
        guard depth == 1 else { return nil }
        serial += 1
        let callers = Thread.callStackSymbols.dropFirst(2).filter { frame in
            !["libswift", "WebKit", "libobjc", "libdispatch", "Foundation", "CoreFoundation", "EvalTrace"].contains { frame.contains($0) }
        }.prefix(6).map { $0.split(separator: " ", omittingEmptySubsequences: true).dropFirst().joined(separator: " ") }
        let page = (web as? WKWebView)?.url?.absoluteString ?? ""
        line(["kind": "eval", "id": serial, "via": via, "gesture": gesture, "world": world,
              "main": frame?.isMainFrame ?? true, "page": String(page.prefix(80)),
              "script": String((script as String).prefix(120)), "callers": Array(callers)])
        return serial
    }

    private static func finish(_ id: Int?, _ done: (@convention(block) (AnyObject?, NSError?) -> Void)?) -> (@convention(block) (AnyObject?, NSError?) -> Void)? {
        guard let id else { return done }
        return { value, error in
            line(["kind": "done", "id": id, "error": error != nil])
            done?(value, error)
        }
    }

    private static func line(_ fields: [String: Any]) {
        var fields = fields
        fields["t"] = Date().timeIntervalSince1970 * 1000
        guard let data = try? JSONSerialization.data(withJSONObject: fields), let text = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardError.write(("EVAL-TRACE " + text + "\n").data(using: .utf8)!)
    }
}
