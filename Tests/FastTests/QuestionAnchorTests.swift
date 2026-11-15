import AppKit
import CoreGraphics
import Testing
@testable import Fast

@Suite(.serialized)
struct QuestionAnchorTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let card = CGSize(width: 420, height: 190)

    @Test func belowWhenItFitsAndAboveNearTheBottom() throws {
        let middle = CGRect(x: 500, y: 400, width: 400, height: 160)
        let below = try #require(QuestionAnchorLayout.place(size: card, anchor: middle, screen: screen))
        #expect(below.side == .below)
        #expect(below.frame.maxY == middle.minY - 16)
        #expect(below.frame.midX == middle.midX)
        let low = CGRect(x: 500, y: 50, width: 400, height: 160)
        let above = try #require(QuestionAnchorLayout.place(size: card, anchor: low, screen: screen))
        #expect(above.side == .above)
        #expect(above.frame.minY == low.maxY + 16)
    }

    @Test func followsMovementAndKeepsItsSideUntilItNoLongerFits() throws {
        let old = CGRect(x: 500, y: 400, width: 400, height: 160)
        let moved = old.offsetBy(dx: 120, dy: 30)
        let a = try #require(QuestionAnchorLayout.place(size: card, anchor: old, screen: screen, preferred: .above))
        let b = try #require(QuestionAnchorLayout.place(size: card, anchor: moved, screen: screen, preferred: a.side))
        #expect(b.side == .above)
        #expect(b.frame.minX == a.frame.minX + 120)
        #expect(b.frame.minY == a.frame.minY + 30)
        let high = CGRect(x: 500, y: 720, width: 400, height: 160)
        let flipped = try #require(QuestionAnchorLayout.place(size: card, anchor: high, screen: screen, preferred: .above))
        #expect(flipped.side == .below)
        #expect(!flipped.frame.intersects(high))
    }

    @Test func horizontalEdgesAndSecondaryDisplayCoordinates() throws {
        let secondary = CGRect(x: -1600, y: 400, width: 1600, height: 1000)
        for anchor in [CGRect(x: -1600, y: 800, width: 240, height: 160),
                       CGRect(x: -240, y: 800, width: 240, height: 160)] {
            let result = try #require(QuestionAnchorLayout.place(size: card, anchor: anchor, screen: secondary))
            #expect(secondary.contains(result.frame))
            #expect(!result.frame.intersects(anchor))
            #expect(result.frame.maxY <= anchor.minY - 16 || result.frame.minY >= anchor.maxY + 16)
        }
    }

    @Test func neverFallsBackToTheSideOrOverTheCode() {
        let short = CGRect(x: 0, y: 0, width: 1440, height: 300)
        let anchor = CGRect(x: 500, y: 80, width: 400, height: 140)
        #expect(QuestionAnchorLayout.place(size: card, anchor: anchor, screen: short) == nil)
        #expect(QuestionAnchorLayout.availableHeight(anchor: anchor, screen: short) == 64)
        #expect(QuestionAnchorLayout.place(size: CGSize(width: 1600, height: 100), anchor: anchor, screen: screen) == nil)
    }

    @Test func aTallerErrorCardFlipsInsteadOfCoveringTheCode() throws {
        let anchor = CGRect(x: 500, y: 240, width: 400, height: 160)
        let initial = try #require(QuestionAnchorLayout.place(size: card, anchor: anchor, screen: screen))
        #expect(initial.side == .below)
        let error = try #require(QuestionAnchorLayout.place(size: CGSize(width: 420, height: 250), anchor: anchor,
                                                          screen: screen, preferred: initial.side))
        #expect(error.side == .above)
        #expect(!error.frame.intersects(anchor))
    }

    private func window(_ pid: Int32, _ frame: CGRect, alpha: Double = 1) -> [String: Any] {
        [kCGWindowOwnerPID as String: NSNumber(value: pid),
         kCGWindowBounds as String: frame.dictionaryRepresentation,
         kCGWindowAlpha as String: NSNumber(value: alpha)]
    }

    @Test func onlyOurHelperWithoutReadingTitlesOrPixels() {
        let actual = CGRect(x: 100, y: 120, width: 400, height: 160)
        let windows = [window(99, actual), window(42, actual, alpha: 0),
                       window(42, CGRect(x: 0, y: 0, width: 10, height: 10)), window(42, actual)]
        #expect(QuestionAnchorLayout.helperFrame(in: windows, processIdentifier: 42, desktopTop: 900)
                == CGRect(x: 100, y: 620, width: 400, height: 160))
        #expect(QuestionAnchorLayout.helperFrame(in: windows, processIdentifier: 77, desktopTop: 900) == nil)
        #expect(QuestionAnchorLayout.helperFrame(in: windows, processIdentifier: 0, desktopTop: 900) == nil)
        #expect(QuestionAnchorLayout.helperFrame(in: [[kCGWindowOwnerPID as String: 42]], processIdentifier: 42, desktopTop: 900) == nil)
    }

    @Test func quartzCoordinatesOnADisplayAboveTheMainOne() {
        let quartz = CGRect(x: -500, y: -800, width: 400, height: 160)
        #expect(QuestionAnchorLayout.helperFrame(in: [window(42, quartz)], processIdentifier: 42, desktopTop: 900)
                == CGRect(x: -500, y: 1540, width: 400, height: 160))
    }

    @MainActor @Test(arguments: [false, true])
    func anchoredPanelOwnsEscapeAndGoesAwayAfterAnswer(_ connected: Bool) async throws {
        _ = NSApplication.shared
        let main = try #require(NSScreen.screens.first)
        let available = try #require(NSScreen.main?.visibleFrame)
        let frame = CGRect(x: available.midX - 200, y: available.midY - 80, width: 400, height: 160)
        let metadata = [window(42, CGRect(x: frame.minX, y: main.frame.maxY - frame.maxY,
                                         width: frame.width, height: frame.height))]
        let anchor = QuestionAnchor(processIdentifier: 42, readWindows: { metadata })
        let questions = Questions()
        let enablement = Question.Enablement()
        let question = Question(title: "Pairing fixture", yes: "", place: .plain, anchor: anchor,
                                enablement: enablement)
        let answer = Task { @MainActor in await questions.ask(question) }
        defer { questions.answer(false); anchor.dismiss() }
        for _ in 0..<100 {
            if anchor.panel?.isVisible == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(anchor.panel)
        #expect(panel.isVisible)
        #expect(questions.current?.place == .plain)
        #expect(questions.stands(in: panel))
        #expect(questions.shownIn.contains(panel.windowNumber))
        let other = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        #expect(!questions.stands(in: other))
        let editor = NSTextView()
        panel.contentView?.addSubview(editor)
        #expect(panel.makeFirstResponder(editor))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        // Another window's Escape cannot cancel this pairing.
        let elsewhere = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: other.windowNumber, context: nil, characters: "\u{1b}",
                                                     charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        #expect(!questions.key(elsewhere))
        #expect(questions.current?.id == question.id)
        if connected {
            // The same route as the sixth digit after Apple's SRP proof.
            enablement.allowed = true
            questions.answer(true)
        } else {
            #expect(questions.key(escape))
        }
        #expect(await answer.value == connected)
        #expect(!panel.isVisible)
        #expect(anchor.panel == nil)
        #expect(questions.shownIn.isEmpty)
    }
}
