import AppKit
import Testing
import WebKit
@testable import Fast

extension NativePasteStyleTests {
    /// Real AppKit responder/control and production field-opener boundaries.
    /// These sources are deferred checks, not a native acceptance result.
    @MainActor @Suite
    struct PasteStyleFocusTests {
        init() throws {
            try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
            _ = NSApplication.shared
        }

        private func board() -> NSPasteboard {
            let board = NSPasteboard(name: .init("yab-paste-style-focus-" + UUID().uuidString))
            board.clearContents()
            board.setString("replacement", forType: .string)
            return board
        }

        /// The key window as AppKit would report it. swift test never runs
        /// NSApp, so a window made key there stays unkeyed (NSApp.keyWindow
        /// nil); ordering it in and naming it here stands for makeKey.
        @MainActor private final class Key {
            var window: NSWindow?
            func make(_ window: NSWindow) {
                window.orderFront(nil)
                self.window = window
            }
        }

        private func window() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -8000, y: -8000, width: 420, height: 220),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
            return window
        }

        private func field(_ value: String, in window: NSWindow, y: CGFloat) -> NSTextField {
            let field = NSTextField(string: value)
            field.frame = NSRect(x: 10, y: y, width: 380, height: 30)
            window.contentView?.addSubview(field)
            return field
        }

        private func editor(of field: NSTextField, in window: NSWindow) throws -> NSTextView {
            try #require(window.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            try #require(editor.isFieldEditor && editor.delegate === field)
            return editor
        }

        private func withBrowser(_ body: (Browser) throws -> Void) throws {
            // Check isolation before Browser or its preferences can initialize.
            try #require(Store.testing && Store.world != nil && Store.settings !== UserDefaults.standard)
            let keys = ["mail", "search.suggest", FieldRequest.key]
            let saved = keys.map { Store.settings.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, saved) {
                    if let value { Store.settings.set(value, forKey: key) }
                    else { Store.settings.removeObject(forKey: key) }
                }
            }
            Store.settings.set(false, forKey: "mail")
            Store.settings.set(false, forKey: "search.suggest")
            Store.settings.set(false, forKey: FieldRequest.key)
            let previousFoldersBrowser = Folders.shared.browser
            let id = UUID(), browser = Browser(windowID: id)
            browser.lookForMailSignInLink = {}
            browser.dropSpare()
            defer {
                browser.dozing?.invalidate(); browser.stuck.timer?.invalidate(); browser.pressure?.cancel()
                browser.letGo()
                browser.dropSpare()
                Folders.shared.browser = previousFoldersBrowser
                try? FileManager.default.removeItem(at: Store.file("spaces-window-\(id.uuidString).json"))
                try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
                Store.settings.removeObject(forKey: "window.\(id.uuidString).space")
            }
            try #require(browser.activeID == nil && browser.tabs.isEmpty)
            try body(browser)
            #expect(browser.activeID == nil && browser.tabs.isEmpty)
        }

        @Test func reusedFieldEditorRejectsStaleDirectTargetButRestoresTheOriginatingControl() throws {
            let window = window(), board = board()
            defer { window.close(); board.releaseGlobally() }
            let original = field("original", in: window, y: 20)
            let query = field("query", in: window, y: 70)
            let first = try editor(of: original, in: window)
            first.selectAll(nil)
            let key = Key()
            let target = PasteStyleTarget(pasteboard: board, keyWindow: { key.window })
            target.capture(in: window)
            let shared = try editor(of: query, in: window)
            try #require(first === shared && shared.delegate === query)
            #expect(!target.perform(), "An identical editor object with a different control is a stale direct target")
            #expect(original.stringValue == "original" && shared.string == "query")

            key.make(window)
            try #require(window.isVisible)
            try #require(target.perform(restoring: true))
            let restored = try #require(original.currentEditor() as? NSTextView)
            #expect(restored.delegate === original && window.firstResponder === restored)
            #expect(restored.string == "replacement")
            #expect(query.stringValue == "query")
            // handBack's field-dismissal callback may preserve this exact
            // restored destination once. It cannot own future tab changes.
            #expect(target.consumeRestoredFocus())
            #expect(!target.consumeRestoredFocus())
        }

        @Test func aDirectCommandStillPastesIntoTheActuallyFocusedQueryControl() throws {
            let window = window(), board = board()
            defer { window.close(); board.releaseGlobally() }
            let original = field("original", in: window, y: 20)
            let query = field("query", in: window, y: 70)
            _ = try editor(of: original, in: window)
            let editor = try editor(of: query, in: window)
            editor.selectAll(nil)
            let target = PasteStyleTarget(pasteboard: board)
            target.capture(in: window)
            try #require(target.perform())
            #expect(editor.string == "replacement")
            #expect(original.stringValue == "original")
            #expect(!target.consumeRestoredFocus())
        }

        @Test func readonlyDetachedAndInactiveDestinationsCannotReceiveARestoredPaste() throws {
            let host = window(), other = window(), board = board()
            defer { host.close(); other.close(); board.releaseGlobally() }
            let original = field("original", in: host, y: 20)
            let query = field("query", in: host, y: 70)
            let key = Key()
            let target = PasteStyleTarget(pasteboard: board, keyWindow: { key.window })
            _ = try editor(of: original, in: host)
            target.capture(in: host)
            let queryEditor = try editor(of: query, in: host)
            original.isEditable = false
            #expect(!target.canPaste(restoring: true) && !target.perform(restoring: true))
            #expect(host.firstResponder === queryEditor && queryEditor.string == "query")
            original.isEditable = true
            key.make(host)
            #expect(target.canPaste(restoring: true), "editable again in the key window, it could take the paste")
            key.make(other)
            #expect(!target.perform(restoring: true))
            #expect(original.stringValue == "original")
            original.removeFromSuperview()
            #expect(!target.canPaste(restoring: true) && !target.perform(restoring: true))
            #expect(!target.consumeRestoredFocus())
        }

        @Test func repeatedQueryRetainsItsOriginAndBothHostTransfersRejectAStaleQueryEditor() throws {
            try withBrowser { browser in
                let main = window(), guest = window(), board = board()
                defer { main.close(); guest.close(); board.releaseGlobally() }
                let mainOriginal = field("main", in: main, y: 20)
                let guestOriginal = field("guest", in: guest, y: 20)
                let coordinator = AddressField.Coordinator(browser: browser)
                let mainQuery = field("Paste and Match Style", in: main, y: 70)
                let guestQuery = field("Paste and Match Style", in: guest, y: 70)
                mainQuery.delegate = coordinator; guestQuery.delegate = coordinator
                let target = PasteStyleTarget(pasteboard: board)
                _ = try editor(of: mainOriginal, in: main)
                target.captureBeforeField(in: main)
                _ = try editor(of: mainQuery, in: main)
                target.captureBeforeField(in: main)
                try #require(target.canPaste(restoring: true))
                mainOriginal.isEditable = false
                #expect(!target.canPaste(restoring: true), "Repeated query must retain mainOriginal rather than capture mainQuery")
                mainOriginal.isEditable = true
                _ = try editor(of: guestQuery, in: guest)
                target.captureBeforeField(in: guest)
                #expect(!target.canPaste(restoring: true))
                _ = try editor(of: guestOriginal, in: guest)
                target.captureBeforeField(in: guest)
                try #require(target.canPaste(restoring: true))
                _ = try editor(of: mainQuery, in: main)
                target.captureBeforeField(in: main)
                #expect(!target.canPaste(restoring: true))
                #expect(mainOriginal.stringValue == "main" && guestOriginal.stringValue == "guest")
            }
        }

        @Test func actualAlreadyOpenGuestEntryRefreshesTheTargetAndUnknownMainEntryDisablesIt() throws {
            try withBrowser { browser in
                let main = window(), guest = window(), board = board()
                defer { main.close(); guest.close(); board.releaseGlobally() }
                let mainOriginal = field("main", in: main, y: 20)
                let guestOriginal = field("guest", in: guest, y: 20)
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let tab = Tab(configuration: configuration)
                defer { tab.close() }
                let target = PasteStyleTarget(pasteboard: board)
                browser.query.pasteStyleTarget = target
                browser.editing = true
                _ = try editor(of: mainOriginal, in: main)
                target.captureBeforeField(in: main)
                let guestEditor = try editor(of: guestOriginal, in: guest)
                guestEditor.selectAll(nil)
                // old editing is already true, so only the real explicit
                // opener can transfer this capture into the guest host.
                browser.edit(over: tab, in: guest)
                try #require(browser.editing && browser.fieldGuest === tab && browser.fieldHost === guest)
                try #require(target.perform())
                #expect((guestOriginal.currentEditor() as? NSTextView)?.string == "replacement")
                #expect(mainOriginal.stringValue == "main")
                // There is deliberately no BrowserWindows association for
                // this synthetic Browser. Returning to main must disable,
                // never capture whichever unrelated window happens to be key.
                browser.edit()
                #expect(browser.fieldGuest == nil && browser.fieldHost == nil)
                #expect(!target.canPaste(restoring: true))
                #expect(tab.builtPage == nil && browser.activeID == nil)
            }
        }
    }
}
