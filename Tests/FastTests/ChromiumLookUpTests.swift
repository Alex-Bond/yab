import AppKit
import JavaScriptCore
import ObjectiveC
import Testing
@testable import Fast

/// #1871: Look Up on Chromium tabs, by Force Click and by three-finger tap.
@MainActor
struct ChromiumLookUpTests {
    /// Both gestures arrive as quickLookWithEvent:. NSView's own answer asks
    /// the text-input client, which never knows a character on this view:
    /// the page view must answer it itself.
    @Test func pageViewAnswersQuickLook() {
        let selector = #selector(NSResponder.quickLook(with:))
        let mine = class_getInstanceMethod(ChromiumPage.self, selector).map(method_getImplementation)
        let stock = class_getInstanceMethod(NSView.self, selector).map(method_getImplementation)
        #expect(mine != nil)
        #expect(mine != stock)
    }

    private func word(_ text: String, _ offset: Int) -> String? {
        let context = JSContext()!
        let value = context.evaluateScript("(\(ChromiumLookUp.wordAt))")!.call(withArguments: [text, offset])!
        return value.isNull ? nil : value.toString()
    }

    @Test func wordUnderThePoint() {
        #expect(word("look up this word", 13) == "word")
        #expect(word("look up this word", 0) == "look")
        #expect(word("look up this word", 17) == "word")
        #expect(word("don't stop", 2) == "don't")
        #expect(word("well-known fact", 6) == "well-known")
        #expect(word("Привет, мир", 2) == "Привет")
        #expect(word("«quoted»", 3) == "quoted")
        #expect(word("'tis", 1) == "tis")
    }

    @Test func nothingBetweenWords() {
        #expect(word("a  b", 2) == nil)
        #expect(word("...", 1) == nil)
        #expect(word("", 0) == nil)
    }

    /// The point goes to the page in its CSS pixels, from the top left.
    @Test func scriptScalesThePoint() {
        let js = ChromiumLookUp.script(at: CGPoint(x: 120, y: 40), width: 800)
        #expect(js.contains("innerWidth / 800.0"))
        #expect(js.contains("x = 120.0 * u, y = 40.0 * u"))
        #expect(js.contains("a[href]"))
        #expect(js.contains("caretRangeFromPoint"))
    }
}
