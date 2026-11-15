// A bare WKWebView in a window, nothing of Yab's around it, loading a
// Google AI Mode address: hook.js at document start, detect.js every
// 250 ms, one JSON line each, and a picture of the page at the end.
//   swiftc -O plain.swift -o plain
//   ./plain URL AGENT SECONDS SHOT.png HOOK.js DETECT.js [FOLLOW-UP]
// With FOLLOW-UP (run.py --flow): URL is an ordinary search; at 8 s the
// page's AI Mode link is pressed, at 28 s the box is focused and the
// follow-up typed into it as key events, then Return.
// AGENT: "webkit" (WKWebView's own, no Safari in it), "safari" (Safari's,
// as Yab says), or any other string as the whole agent.
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 7 || args.count == 8, let address = URL(string: args[1]), let seconds = Double(args[3]) else { exit(2) }
let hook = try! String(contentsOfFile: args[5], encoding: .utf8)
let detect = try! String(contentsOfFile: args[6], encoding: .utf8)
let follow = args.count == 8 ? args[7] : nil
let pressMode = "(() => { const a = [...document.querySelectorAll('a[href*=\\\"udm=50\\\"]')].find((e) => e.getBoundingClientRect().width > 0); if (!a) return 'none'; a.click(); return a.href.slice(0, 120); })()"
let focusBox = "(() => { const b = [...document.querySelectorAll('textarea, [contenteditable]')].find((e) => /ask anything/i.test((e.getAttribute('placeholder') || '') + (e.getAttribute('aria-label') || '') + (e.getAttribute('data-placeholder') || ''))); if (!b) return 'none'; b.scrollIntoView({block: 'center'}); b.focus(); b.click(); return 'ok'; })()"

func safari() -> String {
    for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
        if let v = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String { return v }
    }
    return "26.0"
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let config = WKWebViewConfiguration()
config.userContentController.addUserScript(WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: true))
switch args[2] {
case "webkit": break
case "safari": config.applicationNameForUserAgent = "Version/\(safari()) Safari/605.1.15"
default: break
}
// On the test screen when there is one, never the Mac's own.
let screen = NSScreen.screens.first { $0.localizedName.contains("Test Screen") } ?? NSScreen.screens.last!
let frame = NSRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 1280, height: 800)
let window = NSWindow(contentRect: frame, styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
let web = WKWebView(frame: NSRect(origin: .zero, size: frame.size), configuration: config)
if !["webkit", "safari"].contains(args[2]) { web.customUserAgent = args[2] }
web.autoresizingMask = [.width, .height]
window.contentView = web
window.title = "Plain WebKit"
window.setFrame(window.frameRect(forContentRect: frame), display: true)
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let start = Date()
web.load(URLRequest(url: address))

func out(_ line: String) { FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!) }

func type(_ text: String) {
    window.makeFirstResponder(web)
    for c in text + "\r" {
        let chars = String(c)
        for kind in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                           isARepeat: false, keyCode: c == "\r" ? 36 : 49) else { continue }
            if kind == .keyDown { web.keyDown(with: e) } else { web.keyUp(with: e) }
        }
    }
}

var pressed = false, asked = false
Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
    let t = Date().timeIntervalSince(start)
    if let follow {
        web.evaluateJavaScript("window.__aiFollow = \(String(data: try! JSONEncoder().encode(follow), encoding: .utf8)!); 0", completionHandler: nil)
        if t > 8, !pressed {
            pressed = true
            web.evaluateJavaScript(pressMode) { v, _ in out("{\"t\":\(String(format: "%.2f", t)),\"pressed\":\"\((v as? String) ?? "?")\"}") }
        }
        if t > 28, !asked {
            asked = true
            web.evaluateJavaScript(focusBox) { v, _ in
                out("{\"t\":\(String(format: "%.2f", t)),\"focused\":\"\((v as? String) ?? "?")\"}")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { type(follow) }
            }
        }
    }
    web.evaluateJavaScript(detect) { value, error in
        let said = (value as? String) ?? "{\"error\":\"\(error.map { "\($0.localizedDescription)" } ?? "none")\"}"
        out("{\"t\":\(String(format: "%.2f", t)),\"seen\":\(said)}")
    }
    if t > seconds {
        timer.invalidate()
        web.takeSnapshot(with: nil) { image, _ in
            if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[4]))
            }
            exit(0)
        }
    }
}
app.run()
