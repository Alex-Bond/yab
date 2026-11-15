import AppKit
import Testing
@testable import Fast

@MainActor
struct SelectedURLMenuTests {
    @Test func selectedWebAddressesAreDestinationsButTextPathsAndActiveSchemesAreNot() {
        #expect(SelectedURLMenu.url("https://example.test/path?q=one")?.absoluteString == "https://example.test/path?q=one")
        #expect(SelectedURLMenu.url("  example.test/path  ")?.absoluteString == "https://example.test/path")
        #expect(SelectedURLMenu.url("http://localhost:8080/")?.scheme == "http")
        for text in ["ordinary words", "one\ntwo.test", "javascript:alert(1)", "data:text/html,test", "mailto:a@example.test", "file:///tmp/example", "~/private", "/tmp/private", "about:blank", "https://", "https://user:secret@example.test/"] {
            #expect(SelectedURLMenu.url(text) == nil)
        }
    }

    @Test func directDestinationIsAddedBesideSearchWithoutReplacingOtherActions() {
        let menu = NSMenu(), target = NSObject()
        let search = NSMenuItem(title: "Search with engine", action: nil, keyEquivalent: "")
        search.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        let other = NSMenuItem(title: "Go to “example.test”", action: nil, keyEquivalent: "")
        other.identifier = NSUserInterfaceItemIdentifier("extension/other-action")
        menu.addItem(other); menu.addItem(search)
        let source = URL(string: "https://source.test/")!
        let item = SelectedURLMenu.insert("example.test", source: source, into: menu, target: target, action: NSSelectorFromString("visit:"))
        #expect(item != nil && menu.items.count == 3)
        #expect(menu.items[0] === other && menu.items[2] === search)
        #expect(item?.target === target)
        let destination = item?.representedObject as? SelectedURLMenu.Destination
        #expect(destination?.url.absoluteString == "https://example.test")
        #expect(destination?.source == source)
        #expect(SelectedURLMenu.insert("example.test", source: source, into: menu, target: target, action: NSSelectorFromString("visit:")) == nil)
        #expect(menu.items.count == 3)
    }

    @Test func noSelectionOrNoSearchAnchorAddsNothingAndNewMenuHasFreshDestination() {
        let target = NSObject(), empty = NSMenu()
        #expect(SelectedURLMenu.insert("example.test", source: nil, into: empty, target: target, action: NSSelectorFromString("visit:")) == nil)
        let menu = NSMenu()
        let search = NSMenuItem(title: "Search", action: nil, keyEquivalent: "")
        search.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierSearchWeb")
        menu.addItem(search)
        #expect(SelectedURLMenu.insert("not a URL", source: nil, into: menu, target: target, action: NSSelectorFromString("visit:")) == nil)
        #expect(menu.items.count == 1)
        let item = SelectedURLMenu.insert("other.test", source: nil, into: menu, target: target, action: NSSelectorFromString("visit:"))
        #expect((item?.representedObject as? SelectedURLMenu.Destination)?.url.absoluteString == "https://other.test")
    }

    // Row 979: the selections that missed Go To on 0.39.0.
    @Test func addressesAsSentencesHoldThemAreStillDestinations() {
        let cases = [
            "example.com.": "https://example.com",
            "example.com/comma,": "https://example.com/comma",
            "Example.com!": "https://Example.com",
            "(example.com/paren)": "https://example.com/paren",
            "<https://example.com/angle>": "https://example.com/angle",
            "“example.com/quote”": "https://example.com/quote",
            "\"example.com\"": "https://example.com",
            "[example.com/x].": "https://example.com/x",
            "example.com/x)": "https://example.com/x",
            "https://en.wikipedia.org/wiki/Mercury_(planet)": "https://en.wikipedia.org/wiki/Mercury_(planet)",
            "(https://en.wikipedia.org/wiki/Mercury_(planet)).": "https://en.wikipedia.org/wiki/Mercury_(planet)",
            "\u{00A0}example.com/spaced\u{00A0} ": "https://example.com/spaced",
            "example.com/whole\n\n": "https://example.com/whole",
            "\n  example.com/lead\n": "https://example.com/lead",
            "(example.com/a_(b)": "https://example.com/a_(b)",
            "example.com/q\",": "https://example.com/q",
        ]
        for (words, expected) in cases {
            #expect(SelectedURLMenu.url(words)?.absoluteString == expected, "\(words)")
        }
        for words in ["first.example.com\nsecond.example.com", "example.com and more", "(", "...", "“”", "end.", "(/tmp/private)", "“~/private”"] {
            #expect(SelectedURLMenu.url(words) == nil, "\(words)")
        }
    }

    @Test func linkMenuGetsGoToUnderItsRowsUnlessTheLinkGoesThere() {
        let menu = NSMenu(), target = NSObject()
        for id in ["WKMenuItemIdentifierOpenLinkInNewWindow", "WKMenuItemIdentifierOpenLink", "WKMenuItemIdentifierCopyLink", "WKMenuItemIdentifierShareMenu"] {
            let item = NSMenuItem(title: id, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(id)
            menu.addItem(item)
        }
        let item = SelectedURLMenu.insert("example.com/in-link", source: nil, into: menu, target: target, action: NSSelectorFromString("visit:"))
        #expect(menu.items.firstIndex { $0 === item } == 3)
        #expect(menu.items[2].identifier?.rawValue == "WKMenuItemIdentifierCopyLink")
        #expect(SelectedURLMenu.url("example.com/self", besides: "https://example.com/self") == nil)
        #expect(SelectedURLMenu.url("example.com", besides: "https://example.com/") == nil)
        #expect(SelectedURLMenu.url("example.com/in-link", besides: "https://other.test/")?.absoluteString == "https://example.com/in-link")
        #expect(SelectedURLMenu.url("example.com/plain", besides: "")?.absoluteString == "https://example.com/plain")
        // A menu of neither kind (an image's) gets nothing.
        let image = NSMenu()
        image.addItem(NSMenuItem(title: "Copy Image", action: nil, keyEquivalent: ""))
        #expect(SelectedURLMenu.insert("example.com", source: nil, into: image, target: target, action: NSSelectorFromString("visit:")) == nil)
    }

    @Test func linkMenuReadsOnlyWordsSelectedInsideTheLink() {
        #expect(SelectedURLMenu.selectedInLink.contains("closest('a[href]')"))
        #expect(SelectedURLMenu.selectedInLink.contains("commonAncestorContainer"))
    }
}
