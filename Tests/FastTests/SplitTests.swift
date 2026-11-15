import AppKit
import class SwiftUI.NSHostingController
import Testing
@testable import Fast

// Two tabs side by side, as a session file brings them back: by where each
// tab stood in the file, onto the tabs just made from it. A file written
// wrong, or edited by hand, must never bring back one tab in two pairs, or a
// pair of a tab and itself.
struct SplitTests {
    static let ids = (0..<6).map { _ in UUID() }
    static var made: [Int: UUID] { Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($0.offset, $0.element) }) }

    @Test func restoresPairsByPlace() {
        let pairs = Pair.restore([.init(first: 0, second: 1, share: 0.4), .init(first: 3, second: 4, share: 0.5)], made: Self.made)
        #expect(pairs.count == 2)
        #expect(pairs[0].first == Self.ids[0] && pairs[0].second == Self.ids[1])
        #expect(abs(pairs[0].share - 0.4) < 0.0001)
        #expect(pairs[1].first == Self.ids[3] && pairs[1].second == Self.ids[4])
    }

    @Test func dropsOverlapsSelfPairsAndMissingTabs() {
        let pairs = Pair.restore([
            .init(first: 0, second: 1, share: 0.5),
            .init(first: 1, second: 2, share: 0.5), // 1 is taken already
            .init(first: 2, second: 2, share: 0.5), // a tab and itself
            .init(first: 3, second: 9, share: 0.5), // no tab 9
            .init(first: 4, second: 0, share: 0.5), // 0 is taken already
            .init(first: 4, second: 5, share: 0.5),
        ], made: Self.made)
        #expect(pairs.map(\.first) == [Self.ids[0], Self.ids[4]])
        #expect(pairs.map(\.second) == [Self.ids[1], Self.ids[5]])
    }

    @Test func clampsShares() {
        let pairs = Pair.restore([
            .init(first: 0, second: 1, share: 0.01),
            .init(first: 2, second: 3, share: 7),
            .init(first: 4, second: 5, share: .nan),
        ], made: Self.made)
        #expect(pairs.count == 2)
        #expect(pairs[0].share == Pair.least)
        #expect(pairs[1].share == Pair.most)
    }

    @Test(arguments: [0.0, 1, 7.5, 8, 8.5, 9, 320, 648, 1080])
    func splitMeasurementKeepsFramesInsideRoom(width: Double) {
        let room = CGRect(x: 31, y: 17, width: width, height: 420)
        for share: CGFloat in [0.25, 0.5, 0.75] {
            let layout = SplitLayout(share: share)
            let left = layout.frame(for: .left, in: room)
            let gap = layout.frame(for: .gap, in: room)
            let right = layout.frame(for: .right, in: room)
            for frame in [left, gap, right] {
                #expect(frame.size.width >= 0)
                #expect(frame.minX >= room.minX)
                #expect(frame.maxX <= room.maxX)
                #expect(frame.minY == room.minY && frame.height == room.height)
            }
            #expect(left.maxX == gap.minX)
            #expect(gap.maxX == right.minX)
            #expect(right.maxX == room.maxX)
            #expect(layout.frame(for: .whole, in: room) == room)
            if width >= Pair.room {
                #expect(left.width >= Pair.narrowest && right.width >= Pair.narrowest)
                #expect(gap.width == Pair.gap)
            }
        }
    }

    @MainActor @Test func pageSizeComesFromTheStage() {
        // A page keeps its old frame while a split changes size. That
        // frame must not become the next SwiftUI measurement's answer.
        let page = NSView(frame: CGRect(x: 0, y: 0, width: 1600, height: 1200))
        let host = NSHostingController(rootView: WebStage(page: page))
        for size in [CGSize(width: 320, height: 420), CGSize(width: 1080, height: 730)] {
            #expect(host.sizeThatFits(in: size) == size)
        }
    }

    @MainActor @Test func unchangedStageDoesNotResizePage() {
        let window = NSWindow(contentRect: CGRect(x: -30000, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        let stage = StageView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        stage.autoresizesSubviews = false
        window.contentView = stage
        let page = StageFrameProbe(frame: .zero)
        stage.show(page)
        #expect(page.frame == stage.bounds)
        page.frameWrites = 0
        stage.show(page)
        stage.layout()
        #expect(page.frameWrites == 0)

        stage.setFrameSize(CGSize(width: 500, height: 400))
        stage.layout()
        #expect(page.frameWrites == 1)
        #expect(page.frame == stage.bounds)
    }

    @MainActor @Test func movingCarriesTheOtherHalf() {
        let row = (0..<5).map { _ in Tab() }
        func names(_ tabs: [Tab]) -> [Int] { tabs.map { tab in row.firstIndex { $0 === tab }! } }
        // The second tab, with the third beside it, let go where the fourth is.
        #expect(names(Browser.moving(row, row[1].id, to: 3, with: row[2].id)) == [0, 3, 1, 2, 4])
        // The third, with the second, taken to the front.
        #expect(names(Browser.moving(row, row[2].id, to: 0, with: row[1].id)) == [1, 2, 0, 3, 4])
        // Alone, it moves as a tab always has.
        #expect(names(Browser.moving(row, row[0].id, to: 2, with: nil)) == [1, 2, 0, 3, 4])
    }

    // What shows beside a page held at its size: WebKit's under-page color,
    // never the top bar's first (an orange or navy band opened beside the
    // page on ⇧⌘S), and something dark only when the page is dark and
    // WebKit says white.
    @MainActor @Test func heldPageGround() {
        let hnPage = NSColor(srgbRed: 0.965, green: 0.965, blue: 0.937, alpha: 1)
        let hnBar = NSColor(srgbRed: 1, green: 0.4, blue: 0, alpha: 1)
        let navy = NSColor(srgbRed: 0.07, green: 0.1, blue: 0.2, alpha: 1)
        #expect(StageView.fill(under: hnPage, shade: .light, tone: hnBar) == hnPage)
        #expect(StageView.fill(under: .white, shade: .light, tone: navy) == .white)
        // GitHub, dark, with WebKit's white under it: its own dark top.
        #expect(StageView.fill(under: .white, shade: .dark, tone: navy) == navy)
        // Dark, and the top as light as the default: a plain dark ground.
        let dark = StageView.fill(under: .white, shade: .dark, tone: hnBar)
        #expect(dark.usingColorSpace(.sRGB)!.redComponent < 0.2)
    }

    // ⌥-click on a tab's row puts it beside the page in front (feedback #42).
    // ⇧ and ⌘ keep picking tabs, and win over ⌥ when held with it.
    @Test func optionClickOnARowSplits() {
        #expect(Browser.rowClick([]) == .open)
        #expect(Browser.rowClick(.option) == .split)
        #expect(Browser.rowClick([.option, .capsLock]) == .split)
        #expect(Browser.rowClick(.shift) == .extend)
        #expect(Browser.rowClick(.command) == .gather)
        #expect(Browser.rowClick([.option, .shift]) == .extend)
        #expect(Browser.rowClick([.option, .command]) == .gather)
    }

    @Test func optionClickPlacesTheTab() {
        let (page, other, partner) = (Self.ids[0], Self.ids[1], Self.ids[2])
        // The page in front itself: nothing.
        #expect(Browser.splitClick(clicked: page, current: page, partner: nil) == .nothing)
        #expect(Browser.splitClick(clicked: page, current: page, partner: partner) == .nothing)
        // A page alone: the tab beside it.
        #expect(Browser.splitClick(clicked: other, current: page, partner: nil) == .beside)
        // Half of a pair already: the tab in place of the other half.
        #expect(Browser.splitClick(clicked: other, current: page, partner: partner) == .instead(partner))
        // The other half: only brought in front.
        #expect(Browser.splitClick(clicked: partner, current: page, partner: partner) == .open)
        // No page in front: opened.
        #expect(Browser.splitClick(clicked: other, current: nil, partner: nil) == .open)
    }

    // ⌃Tab walks a pair as one tab, as Arc does (feedback #675): only the
    // half that comes first, the one you are on or looked at last, stays.
    @Test func controlTabTakesAPairAsOneTab() {
        let id = Self.ids
        let pairs = [Pair(first: id[0], second: id[1]), Pair(first: id[3], second: id[4])]
        // On the left half, the right one looked at just before: ⌃Tab goes
        // to the tab before the pair, not to its other half.
        #expect(Switcher.onePerPair([id[0], id[1], id[2]], pairs: pairs) == [id[0], id[2]])
        // On the right half: the same, the right half kept.
        #expect(Switcher.onePerPair([id[1], id[0], id[2]], pairs: pairs) == [id[1], id[2]])
        // Another pair further back is one tile too, its last half looked at.
        #expect(Switcher.onePerPair([id[2], id[4], id[5], id[3], id[0]], pairs: pairs) == [id[2], id[4], id[5], id[0]])
        // No pairs: nothing changes.
        #expect(Switcher.onePerPair([id[1], id[0]], pairs: []) == [id[1], id[0]])
    }
}

@MainActor
private final class StageFrameProbe: NSView {
    var frameWrites = 0
    override var frame: NSRect {
        didSet { frameWrites += 1 }
    }
}
