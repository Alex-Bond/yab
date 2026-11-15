import AppKit
import Testing
import WebKit
@testable import Fast

/// #949, #1563: a page taken out of the window with the keys must be asked
/// to give them up. AppKit takes them without asking, and WebKit lets
/// Secure Event Input go only in its resignFirstResponder: a tab switched
/// away from with a password field focused left it on, and macOS then kept
/// Caps Lock from switching input sources in every app.
@MainActor @Suite(.serialized)
struct PageViewResponderTests {
    final class Keys: NSView {
        var resigned = 0
        override var acceptsFirstResponder: Bool { true }
        override func resignFirstResponder() -> Bool {
            resigned += 1
            return super.resignFirstResponder()
        }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            giveUpKeys(leavingFor: newWindow)
            super.viewWillMove(toWindow: newWindow)
        }
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -9000, y: -9000, width: 300, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aViewTakenOutWithTheKeysIsAskedToGiveThemUp() throws {
        let window = window()
        defer { window.close() }
        let holder = NSView(frame: window.contentView!.bounds)
        let page = Keys(frame: holder.bounds)
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        holder.addSubview(page)
        page.addSubview(field)
        window.contentView?.addSubview(holder)

        // The view itself.
        #expect(window.makeFirstResponder(page))
        page.removeFromSuperview()
        #expect(page.resigned == 1)
        #expect(window.firstResponder === window)

        // A view inside it: the one with the keys resigns.
        holder.addSubview(page)
        #expect(window.makeFirstResponder(field))
        page.removeFromSuperview()
        #expect(window.firstResponder !== field)

        // Without the keys, nothing is asked of it.
        holder.addSubview(page)
        let other = Keys(frame: .zero)
        holder.addSubview(other)
        #expect(window.makeFirstResponder(other))
        let before = page.resigned
        page.removeFromSuperview()
        #expect(page.resigned == before)
        #expect(window.firstResponder === other)
    }

    @Test func pageViewsGiveUpTheKeysAsTheyLeave() throws {
        let window = window()
        defer { window.close() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let tab = Tab(shy: true, bench: true, configuration: configuration)
        defer { tab.close() }
        let web = try #require(tab.webKitOnly("Responder fixture"))
        web.frame = window.contentView!.bounds
        window.contentView?.addSubview(web)
        #expect(window.makeFirstResponder(web))
        // As the stage takes it out: asked first, while still in the window.
        web.viewWillMove(toWindow: nil)
        #expect(window.firstResponder !== web)
        web.removeFromSuperview()
    }
}
