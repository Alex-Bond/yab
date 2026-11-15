import AppKit
import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ColumnHitTabTests {
    private func world(_ body: (Browser, Tab, Tab) -> Void) {
        _ = NSApplication.shared
        let id = UUID()
        let browser = Browser(windowID: id)
        browser.lay([])
        let first = browser.open(URL(string: "about:blank#first")!, foreground: false)
        let second = browser.open(URL(string: "about:blank#second")!, foreground: false)
        browser.pin(first)
        browser.pin(second)
        defer {
            browser.letGo()
            try? FileManager.default.removeItem(at: Store.file("session-window-\(id.uuidString).json"))
        }
        body(browser, first, second)
    }

    private func bind(_ cell: ColumnCell, _ kind: ColumnItem.Kind, _ browser: Browser, id: String) {
        cell.frame = CGRect(x: 0, y: 0, width: 240, height: 34)
        cell.bind(ColumnItem(id: id, kind: kind, indent: 0, y: 0, height: 34),
                  .init(browser: browser, look: .init(tone: nil, scheme: .light, titleSize: 13, grain: 0), liveID: nil),
                  force: true)
    }

    @Test(arguments: ["pin", "home", "tab"])
    func aSingleTabIsResolvedWithoutHover(_ kind: String) {
        world { browser, first, second in
            let cell = ColumnCell(kind: kind == "pin" ? .pin : kind == "home" ? .home : .tab)
            let item: ColumnItem.Kind = kind == "pin" ? .pin(first) : kind == "home" ? .home(first) : .tab(first)
            bind(cell, item, browser, id: first.id.uuidString)
            #expect(cell.tabUnderPointer(hovered: nil) == first.id)
            #expect(cell.tabUnderPointer(hovered: second) == first.id)
        }
    }

    @Test func aReusedPinCellNamesTheNewPinDespiteOldHover() {
        world { browser, first, second in
            let cell = ColumnCell(kind: .pin)
            bind(cell, .pin(first), browser, id: first.id.uuidString)
            bind(cell, .pin(second), browser, id: second.id.uuidString)
            #expect(cell.tabUnderPointer(hovered: first) == second.id)
            #expect(cell.tabUnderPointer(hovered: nil) == second.id)
        }
    }

    @Test(arguments: [false, true])
    func aPairStillResolvesItsOwnHoveredHalf(pinned: Bool) {
        world { browser, first, second in
            browser.pairs.append(Pair(first: first.id, second: second.id, share: 0.5))
            let cell = ColumnCell(kind: pinned ? .pin : .pair)
            bind(cell, pinned ? .pin(first) : .pair(first, second), browser, id: first.id.uuidString)
            #expect(cell.tabUnderPointer(hovered: nil) == nil)
            #expect(cell.tabUnderPointer(hovered: first) == first.id)
            #expect(cell.tabUnderPointer(hovered: second) == second.id)
            #expect(cell.tabUnderPointer(hovered: Tab()) == nil)
        }
    }
}
