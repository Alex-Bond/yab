import AppKit
import Testing
import WebKit
@testable import Fast

extension NativeAppleModelTests {
    @MainActor
    struct AppleWritingToolsTests {
        @Test func configurationFollowsBothSettings() throws {
            try withChoice {
                #expect(AppleWritingTools.behavior(enabled: true) == .default)
                #expect(AppleWritingTools.behavior(enabled: false) == .none)
                for enabled in [false, true] {
                    AppleModelAccess.enabled = enabled
                    let configuration = WKWebViewConfiguration()
                    configuration.websiteDataStore = .nonPersistent()
                    configuration.writingToolsBehavior = .complete
                    AppleWritingTools.configure(configuration)
                    let expected = AppleWritingTools.behavior(enabled: enabled)
                    #expect(configuration.writingToolsBehavior == expected)

                    // A popup or restored tab can carry an older configuration.
                    configuration.writingToolsBehavior = enabled ? .none : .complete
                    let page = PageView(frame: .zero, configuration: configuration)
                    #expect(page.configuration.writingToolsBehavior == expected)
                }
            }
        }

        @Test func existingWebViewsKeepTheirCreationPolicy() throws {
            try withChoice {
                AppleModelAccess.enabled = true
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                let page = PageView(frame: .zero, configuration: configuration)
                let original = page.configuration.writingToolsBehavior
                AppleModelControl().setEnabled(false)
                AppleWritingTools.configure(configuration)
                AppleWritingTools.configure(page.configuration)
                #expect(configuration.writingToolsBehavior == .none)
                #expect(page.configuration.writingToolsBehavior == original)
                let replacement = PageView(frame: .zero, configuration: configuration)
                #expect(replacement.configuration.writingToolsBehavior == .none)
            }
        }

        @Test func nativeEditingFollowsLiveChanges() throws {
            try withChoice {
                _ = AppleWritingTools.shared
                AppleModelAccess.enabled = true
                let text = NSTextView()
                text.isFieldEditor = true
                text.writingToolsBehavior = .limited
                let original = text.writingToolsBehavior
                let control = AppleModelControl()
                control.setEnabled(false)
                NotificationCenter.default.post(name: NSText.didBeginEditingNotification, object: text)
                #expect(text.writingToolsBehavior == .none)
                control.setEnabled(true)
                #expect(text.writingToolsBehavior == original)

                // Reuse the editor after it has already been restored once.
                control.setEnabled(false)
                NotificationCenter.default.post(name: NSText.didBeginEditingNotification, object: text)
                #expect(text.writingToolsBehavior == .none)
                control.setEnabled(true)
                #expect(text.writingToolsBehavior == original)
            }
        }

        @Test func selectionChangesDoNotApplyBehavior() throws {
            try withChoice {
                _ = AppleWritingTools.shared
                AppleModelAccess.enabled = false
                let text = NSTextView()
                text.writingToolsBehavior = .limited
                NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: text)
                #expect(text.writingToolsBehavior == .limited)
                NotificationCenter.default.post(name: NSText.didBeginEditingNotification, object: text)
                #expect(text.writingToolsBehavior == .none)
                AppleModelAccess.enabled = true
                #expect(text.writingToolsBehavior == .limited)
            }
        }

        @Test func keyChangesOnlyApplyToTheWindowsFirstResponder() throws {
            try withChoice {
                _ = AppleWritingTools.shared
                AppleModelAccess.enabled = false
                let window = makeWindow(), other = makeWindow()
                defer { window.close(); other.close() }
                let root = CountingView(), otherRoot = CountingView()
                window.contentView = root
                other.contentView = otherRoot
                let focused = NSTextView(), idle = NSTextView(), otherText = NSTextView()
                root.addSubview(focused)
                root.addSubview(idle)
                otherRoot.addSubview(otherText)
                try #require(window.makeFirstResponder(focused))
                try #require(other.makeFirstResponder(otherText))
                for text in [focused, idle, otherText] { text.writingToolsBehavior = .limited }
                let tracked = NSTextView()
                AppleWritingTools.shared.apply(to: tracked)
                tracked.writingToolsBehavior = .limited
                root.reads = 0
                otherRoot.reads = 0

                for _ in 0..<3 {
                    NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
                }
                #expect(root.reads == 0)
                #expect(otherRoot.reads == 0)
                #expect(focused.writingToolsBehavior == .none)
                #expect(idle.writingToolsBehavior == .limited)
                #expect(otherText.writingToolsBehavior == .limited)
                #expect(tracked.writingToolsBehavior == .limited)

                // Only a real setting change walks the windows, once each.
                let control = AppleModelControl()
                control.setEnabled(true)
                #expect(root.reads == 1)
                #expect(otherRoot.reads == 1)
                root.reads = 0
                otherRoot.reads = 0
                control.setEnabled(false)
                #expect(root.reads == 1)
                #expect(otherRoot.reads == 1)
                #expect(idle.writingToolsBehavior == .none)
                #expect(otherText.writingToolsBehavior == .none)
                root.reads = 0
                otherRoot.reads = 0
                control.setEnabled(false)
                #expect(root.reads == 0)
                #expect(otherRoot.reads == 0)
            }
        }

        @Test func ownedEditorsStartDisabledAndRestoreTheirBehavior() throws {
            try withChoice {
                AppleModelAccess.enabled = true
                let addressBehavior = AddressEditor.make().writingToolsBehavior
                let mailBehavior = MailWordsView.make().writingToolsBehavior
                AppleModelAccess.enabled = false
                let address = AddressEditor.make()
                let mail = MailWordsView.make()
                #expect(address.writingToolsBehavior == .none)
                #expect(mail.writingToolsBehavior == .none)
                #expect(address.isFieldEditor)
                #expect(mail.isEditable)
                AppleModelAccess.enabled = true
                #expect(address.writingToolsBehavior == addressBehavior)
                #expect(mail.writingToolsBehavior == mailBehavior)
                AppleModelAccess.enabled = false
                AppleWritingTools.shared.apply(to: address)
                AppleWritingTools.shared.apply(to: mail)
                #expect(address.writingToolsBehavior == .none)
                #expect(mail.writingToolsBehavior == .none)
            }
        }

        @Test func reenablePreservesAnEditorsExistingOptOut() throws {
            try withChoice {
                AppleModelAccess.enabled = true
                let text = NSTextView()
                text.writingToolsBehavior = .none
                AppleModelAccess.enabled = false
                AppleWritingTools.shared.apply(to: text)
                AppleModelAccess.enabled = true
                #expect(text.writingToolsBehavior == .none)
            }
        }

        private func withChoice(_ body: () throws -> Void) throws {
            _ = NSApplication.shared
            try #require(Store.testing && Store.world != nil)
            try #require(Store.settings !== UserDefaults.standard)
            let settings = Store.settings
            let old = settings.object(forKey: AppleModelAccess.disabledKey)
            defer {
                if let old { settings.set(old, forKey: AppleModelAccess.disabledKey) }
                else { settings.removeObject(forKey: AppleModelAccess.disabledKey) }
                NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
            }
            try body()
        }

        private func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 400, height: 200),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            return window
        }

        private final class CountingView: NSView {
            var reads = 0
            override var subviews: [NSView] {
                get { reads += 1; return super.subviews }
                set { super.subviews = newValue }
            }
        }
    }
}
