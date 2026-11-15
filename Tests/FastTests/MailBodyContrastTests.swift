import AppKit
import Testing
import WebKit
@testable import Fast
@testable import MailCore

struct MailBodyContrastTests {
    @Test @MainActor func darkMailKeepsTextReadableAcrossSenderBackgrounds() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = MailBodyView(frame: NSRect(x: 0, y: 0, width: 700, height: 440), configuration: config)
        web.appearance = NSAppearance(named: .darkAqua)
        web.setValue(false, forKey: "drawsBackground")
        let coordinator = MailBody.Coordinator()
        web.navigationDelegate = coordinator
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -1200, y: -1200))
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        let html = """
        <body style="color:#111">
          <p id="plain" style="color:#111">A reminder with dark text on the transparent mail surface.</p>
          <p id="link"><a href="https://example.test" style="color:blue">A link in the message</a></p>
          <table style="background:#fff;width:100%"><tr><td style="padding:16px">
            <span id="white" style="color:#111">A white signature card with dark text.</span>
          </td></tr></table>
          <div style="background:#111;padding:16px"><span id="dark" style="color:#fff">A dark card with light text.</span></div>
        </body>
        """
        web.loadHTMLString(MailHTML.clean(html), baseURL: nil)

        var result: [String: Any] = [:]
        for _ in 0..<100 {
            result = (try? await web.evaluateJavaScript("""
            ({dark:matchMedia('(prefers-color-scheme: dark)').matches,
              plain:document.getElementById('plain')?.style.color,
              white:document.getElementById('white')?.style.color,
              darkCard:document.getElementById('dark')?.style.color,
              link:document.querySelector('#link a')?.style.color})
            """)) as? [String: Any] ?? [:]
            if result["plain"] as? String == "rgb(237, 237, 237)" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(result["dark"] as? Bool == true)
        #expect(result["plain"] as? String == "rgb(237, 237, 237)")
        #expect(result["white"] as? String == "rgb(17, 17, 17)")
        #expect(result["darkCard"] as? String == "rgb(255, 255, 255)")
        #expect(result["link"] as? String == "rgb(237, 237, 237)")

        if let path = ProcessInfo.processInfo.environment["YAB_MAIL_CONTRAST_SHOT"] {
            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
                }
            }
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
        }

        // A reopened message after a theme change must use the sender's light
        // colors again, without the dark-mode overrides left on its elements.
        web.appearance = NSAppearance(named: .aqua)
        web.loadHTMLString(MailHTML.clean(html), baseURL: nil)
        for _ in 0..<100 {
            result = (try? await web.evaluateJavaScript("""
            ({dark:matchMedia('(prefers-color-scheme: dark)').matches,
              plain:document.getElementById('plain')?.style.color,
              white:document.getElementById('white')?.style.color,
              darkCard:document.getElementById('dark')?.style.color})
            """)) as? [String: Any] ?? [:]
            if result["dark"] as? Bool == false && result["plain"] as? String == "rgb(17, 17, 17)" { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(result["dark"] as? Bool == false)
        #expect(result["plain"] as? String == "rgb(17, 17, 17)")
        #expect(result["white"] as? String == "rgb(17, 17, 17)")
        #expect(result["darkCard"] as? String == "rgb(255, 255, 255)")
    }

    @Test @MainActor func locallySuppliedMessageRendersInDarkMode() async throws {
        guard let path = ProcessInfo.processInfo.environment["YAB_MAIL_HTML_FILE"] else { return }
        let html = try String(contentsOfFile: path, encoding: .utf8)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let web = MailBodyView(frame: NSRect(x: 0, y: 0, width: 1150, height: 1100), configuration: config)
        web.appearance = NSAppearance(named: .darkAqua)
        web.setValue(false, forKey: "drawsBackground")
        let coordinator = MailBody.Coordinator()
        web.navigationDelegate = coordinator
        let window = NSWindow(contentRect: web.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.setFrameOrigin(NSPoint(x: -1200, y: -1200))
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        web.loadHTMLString(MailHTML.clean(html), baseURL: nil)

        var state: [String: Any] = [:]
        for _ in 0..<100 {
            state = (try? await web.evaluateJavaScript("""
            ({ready:document.readyState,
              dark:matchMedia('(prefers-color-scheme: dark)').matches,
              length:document.body?.innerText.length || 0,
              corrected:[...document.body.querySelectorAll('*')].filter(e => e.style.getPropertyPriority('color') === 'important').length})
            """)) as? [String: Any] ?? [:]
            if state["ready"] as? String == "complete" && (state["corrected"] as? Int ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(state["dark"] as? Bool == true)
        #expect((state["length"] as? Int ?? 0) > 200)
        #expect((state["corrected"] as? Int ?? 0) > 0)

        if let shot = ProcessInfo.processInfo.environment["YAB_MAIL_ACTUAL_SHOT"] {
            let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSImage, Error>) in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CocoaError(.fileWriteUnknown)) }
                }
            }
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: shot), options: .atomic)
        }
    }
}
