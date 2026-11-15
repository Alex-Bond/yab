import Foundation
import QuartzCore
import Testing
@testable import Fast

/// Elements' tree: its lines, its keys, and that nothing in it
/// grows faster than the page (X: 20,000 nodes, 40 and more levels deep).
@Suite @MainActor struct DevTreeTests {
    private func el(_ id: Int, _ tag: String, _ children: [DevDOMNode] = [], attrs: [[String]]? = nil) -> DevDOMNode {
        DevDOMNode(id: id, type: 1, label: "<\(tag)>", count: children.count, children: children, name: tag, attrs: attrs)
    }
    private func text(_ id: Int, _ words: String) -> DevDOMNode {
        DevDOMNode(id: id, type: 3, label: "#text", count: 0, children: [], name: "#text", value: words)
    }
    private func doc(_ children: [DevDOMNode]) -> DevDOMNode {
        DevDOMNode(id: 1, type: 9, label: "#document", count: children.count, children: children, name: "#document", value: "https://example.test/")
    }

    /// An X-like page: a spine `depth` levels deep, every level with
    /// `fan` siblings that each hold a small subtree, about `total` nodes.
    private func xLike(depth: Int = 45, total: Int = 20_000) -> (root: DevDOMNode, deepest: Int, count: Int) {
        var next = 10
        func id() -> Int { next += 1; return next }
        let perLevel = max(1, total / depth / 6)
        func leafy() -> DevDOMNode {
            let a = id()
            return el(a, "div", [el(id(), "span", [text(id(), "words")]), el(id(), "a", [text(id(), "link")], attrs: [["href", "/x"]]), text(id(), "  \n ")], attrs: [["class", "r-1"]])
        }
        var deepest = 0
        func spine(_ level: Int) -> DevDOMNode {
            let me = id()
            if level == depth { deepest = me; return el(me, "span", [text(id(), "the deepest")]) }
            var kids = (0..<perLevel).map { _ in leafy() }
            kids.insert(spine(level + 1), at: kids.count / 2)
            return el(me, "div", kids, attrs: [["class", "css-175oi2r"], ["data-level", String(level)]])
        }
        let body = el(4, "body", [spine(0)])
        let root = doc([DevDOMNode(id: 2, type: 10, label: "html", count: 0, children: [], name: "html"), el(3, "html", [el(5, "head"), body])])
        return (root, deepest, next)
    }

    private func ms(_ work: () -> Void) -> Double {
        let start = CACurrentMediaTime(); work(); return (CACurrentMediaTime() - start) * 1000
    }

    @Test func parsesTheInspectorsAnswerWithoutTheCodableRoundTrip() throws {
        let json = ##"{"id":1,"type":9,"label":"#document","count":1,"name":"#document","value":"https://a.test/","children":[{"id":3,"type":1,"label":"<html>","count":2,"name":"html","attrs":[["lang","en"],["hidden"]],"layout":"grid","children":[{"id":4,"type":3,"label":"#text x","count":0,"name":"#text","value":"x","children":[]}]}]}"##
        let any = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let fast = try #require(DevDOMNode(json: any))
        let slow = try JSONDecoder().decode(DevDOMNode.self, from: Data(json.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(try encoder.encode(fast) == encoder.encode(slow))
        #expect(fast.children[0].attrs == [["lang", "en"], ["hidden"]])
        #expect(fast.children[0].layout == "grid")
        #expect(DevDOMNode(json: ["type": 1]) == nil)
    }

    @Test func linesAreChromesClosingTagsVoidElementsAndShortTexts() {
        let root = doc([el(3, "html", [
            el(5, "head"),
            el(6, "body", [
                text(7, "\n  "),
                el(8, "p", [text(9, "Hello")]),
                el(10, "img", attrs: [["src", "a.png"]]),
                el(11, "canvas", [el(12, "span", [text(13, "fallback")])]),
                el(14, "div", [el(15, "b", [text(16, "x")]), text(17, "y")]),
                text(18, "\u{A0}"),
            ]),
        ])])
        let lines = DevTreeLine.lines(root, open: [3, 6, 11, 14])
        let ids = lines.map(\.id)
        #expect(ids == ["o3", "o5", "o6", "o8", "o10", "o11", "o12", "o14", "o15", "o17", "c14", "o18", "c6", "c3"])
        // The canvas is open but has no closing line.
        #expect(!ids.contains("c11"))
        #expect(String(lines[3].text(picked: false).characters) == "<p>Hello</p>")
        #expect(String(lines[4].text(picked: false).characters) == "<img src=\"a.png\">")
        // A text of no-break spaces is shown, as its entity.
        #expect(String(lines[11].text(picked: false).characters) == "\"&nbsp;\"")
        #expect(DevTreeLine.entitied("a\u{200B}b\u{A0}") == "a&ZeroWidthSpace;b&nbsp;")
        #expect(DevTreeLine.entitied("plain") == "plain")
    }

    @Test func findIndexAndPathStayLinearOnADeepTree() {
        let (root, deepest, count) = xLike()
        #expect(count > 15_000)
        var found: DevDOMNode?
        let findMs = ms { found = root.find(deepest) }
        #expect(found?.id == deepest)
        var index = DevTreeIndex(nil)
        let indexMs = ms { index = DevTreeIndex(root) }
        let path = index.path(to: deepest)
        #expect(path.count == 45 + 4)
        #expect(path.first == 1 && path.last == deepest)
        // Debug builds: generous; the exponential find took minutes.
        #expect(findMs < 200, "find took \(findMs) ms")
        #expect(indexMs < 500, "index took \(indexMs) ms")
    }

    @Test func selectingTheDeepestNodeIsQuickAndMakesTheLinesOnce() {
        let (root, deepest, _) = xLike()
        let model = DevWorkbench()
        model.root = root
        var lines = 0
        let revealMs = ms {
            model.revealNode(deepest)
            model.selectedNode = deepest
            lines = model.treeLines.lines.count
        }
        #expect(model.expanded.count == 45 + 3)
        #expect(lines > 45)
        #expect(model.treeLines.at(deepest, close: false) != nil)
        #expect(model.treeLines.maxDepth >= 45)
        #expect(revealMs < 300, "reveal took \(revealMs) ms")
        // A redraw, a hover, a sidebar answer: the same lines, not made again.
        let made = model.linesMade
        for _ in 0..<50 { _ = model.treeLines }
        model.selectedNode = 4
        _ = model.treeLines
        #expect(model.linesMade == made)
        model.expanded.insert(5)
        _ = model.treeLines
        #expect(model.linesMade == made + 1)
        model.root = root
        _ = model.treeLines
        #expect(model.linesMade == made + 2)
    }

    @Test func revealingAnOpenPathPublishesNothing() {
        let (root, deepest, _) = xLike(depth: 10, total: 500)
        let model = DevWorkbench()
        model.root = root
        model.revealNode(deepest)
        let made = model.linesMade
        _ = model.treeLines
        model.revealNode(deepest)
        _ = model.treeLines
        #expect(model.linesMade == made + 1)
    }

    @Test func keysMoveAsChromesTree() {
        let root = doc([el(3, "html", [el(5, "head"), el(6, "body", [el(8, "div", [el(9, "span", [text(10, "a")]), el(11, "i", [text(12, "b")])]), el(13, "p")])])])
        var open: Set<Int> = [3, 6, 8]
        var lines = DevTreeLine.lines(root, open: open)
        let place = { (id: String) in lines.firstIndex { $0.id == id }! }
        #expect(lines.map(\.id) == ["o3", "o5", "o6", "o8", "o9", "o11", "c8", "o13", "c6", "c3"])
        #expect(DevTreeKeys.up(lines, from: nil) == .select(lines.count - 1))
        #expect(DevTreeKeys.down(lines, from: nil) == .select(0))
        #expect(DevTreeKeys.down(lines, from: place("o11")) == .select(place("c8")))
        #expect(DevTreeKeys.up(lines, from: 0) == .none)
        #expect(DevTreeKeys.down(lines, from: lines.count - 1) == .none)
        // ←: an open node closes, a closing tag goes to its opening line,
        // a leaf to its parent, the top line nowhere.
        #expect(DevTreeKeys.left(lines, from: place("o8"), open: open, option: false) == .collapse(8, deep: false))
        #expect(DevTreeKeys.left(lines, from: place("o8"), open: open, option: true) == .collapse(8, deep: true))
        #expect(DevTreeKeys.left(lines, from: place("c8"), open: open, option: false) == .select(place("o8")))
        #expect(DevTreeKeys.left(lines, from: place("o11"), open: open, option: false) == .select(place("o8")))
        #expect(DevTreeKeys.left(lines, from: place("o5"), open: open, option: false) == .select(place("o3")))
        #expect(DevTreeKeys.left(lines, from: place("o3"), open: [], option: false) == .none)
        // →: a closed node opens, an open one goes to its first child, a
        // leaf and a closing tag stay.
        #expect(DevTreeKeys.right(lines, from: place("o8"), open: open, option: false) == .select(place("o9")))
        #expect(DevTreeKeys.right(lines, from: place("o8"), open: open, option: true) == .expand(8, deep: true))
        #expect(DevTreeKeys.right(lines, from: place("c8"), open: open, option: false) == .none)
        #expect(DevTreeKeys.right(lines, from: place("o13"), open: open, option: false) == .none)
        open.remove(8)
        lines = DevTreeLine.lines(root, open: open)
        #expect(DevTreeKeys.right(lines, from: place("o8"), open: open, option: false) == .expand(8, deep: false))
        #expect(DevTreeKeys.parentLine(lines, of: place("o13")) == place("o6"))
    }

    @Test func deletingSelectsTheNextSiblingThenTheOneBeforeThenTheParent() {
        let root = doc([el(3, "html", [el(5, "head"), el(6, "body", [el(8, "a"), text(9, "  "), el(10, "b"), el(11, "c")])])])
        let index = DevTreeIndex(root)
        #expect(DevTreeKeys.afterRemoval(8, in: index) == 10)
        #expect(DevTreeKeys.afterRemoval(11, in: index) == 10)
        let lone = DevTreeIndex(doc([el(3, "html", [el(6, "body", [el(8, "a")])])]))
        #expect(DevTreeKeys.afterRemoval(8, in: lone) == 6)
        #expect(DevTreeKeys.afterRemoval(3, in: lone) == nil)
        #expect(Set(DevTreeKeys.subtree(6, in: index)) == [6])
        #expect(Set(DevTreeKeys.subtree(3, in: index)) == [3, 6])
    }

    /// The ways this replaced, timed against it on the same trees: the
    /// Codable round trip of every tree fetched, Expand Recursively's search
    /// from the root for every node under the one opened (n²), the path
    /// under the tree walked from the root on every redraw.
    @Test func theOldWaysAgainstTheNew() throws {
        let (root, deepest, _) = xLike()
        let any = try JSONSerialization.jsonObject(with: JSONEncoder().encode(root))
        let oldParse = ms { _ = try? JSONDecoder().decode(DevDOMNode.self, from: JSONSerialization.data(withJSONObject: any)) }
        let newParse = ms { _ = DevDOMNode(json: any) }
        let small = xLike(depth: 45, total: 3_000).root
        var expanded = Set<Int>()
        func expandAll(_ id: Int) { if let n = small.find(id) { expanded.insert(id); n.children.forEach { expandAll($0.id) } } }
        let oldExpand = ms { expandAll(4) }
        let newExpand = ms { _ = DevTreeKeys.subtree(4, in: DevTreeIndex(small)) }
        func path(_ node: DevDOMNode) -> [DevDOMNode]? {
            if node.id == deepest { return [node] }
            for c in node.children { if let p = path(c) { return [node] + p } }
            return nil
        }
        let oldPath = ms { for _ in 0..<20 { _ = path(root) } } / 20
        let index = DevTreeIndex(root)
        let newPath = ms { for _ in 0..<20 { _ = index.path(to: deepest).compactMap { index.nodes[$0] } } } / 20
        print(String(format: "DEVTREE before/after: parse 20k %.1f / %.1f ms, expand all 3k %.1f / %.1f ms, path per redraw %.2f / %.3f ms",
                     oldParse, newParse, oldExpand, newExpand, oldPath, newPath))
        #expect(newParse < oldParse)
        #expect(newExpand < oldExpand)
        #expect(newPath < oldPath)
    }

    @Test func linesForTwentyThousandOpenNodesAreMadeQuickly() {
        let (root, _, _) = xLike()
        let open = Set(DevTreeKeys.subtree(1, in: DevTreeIndex(root)))
        var made: DevTreeLines?
        let took = ms { made = DevTreeLines(DevTreeLine.lines(root, open: open)) }
        #expect((made?.lines.count ?? 0) > 10_000)
        #expect(took < 1500, "lines took \(took) ms")
    }

    /// The table counts a line's width instead of laying it out (DevTreeTable
    /// heightOfRow): the count has to be what the drawing measures, or a
    /// line that wraps would be cut, and one in another script measured.
    @Test func aLinesCountedWidthIsItsDrawnWidth() {
        let root = doc([el(3, "html", [
            el(5, "head"),
            el(6, "body", [
                el(8, "p", [text(9, "Hello there")], attrs: [["class", "a b"], ["hidden"]]),
                el(10, "img", attrs: [["src", "a.png"], ["alt", ""]]),
                el(11, "div", [el(12, "span", [text(13, "x")]), text(14, "y")], attrs: [["id", "wrap"]]),
                DevDOMNode(id: 15, type: 8, label: "#comment", count: 0, children: [], name: "#comment", value: " a comment "),
                el(16, "section", [el(17, "b")], attrs: [["style", "display: grid"]]),
                text(18, "plain words"),
                el(19, "p", [text(20, "Grüß dich")]),
                text(21, "\u{A0}"),
            ]),
        ])])
        var grid = root
        grid.children[0].children[1].children[4].layout = "grid"
        let lines = DevTreeLine.lines(grid, open: [3, 6])
        var counted = 0
        for line in lines {
            for picked in [false, true] {
                let drawn = line.attributed(picked: picked).size().width
                if let width = line.plainWidth(picked: picked) {
                    counted += 1
                    #expect(abs(width - drawn) < 0.5, "\(line.id) picked \(picked): counted \(width), drawn \(drawn)")
                }
            }
        }
        #expect(counted >= 14)
        // Another script and an entity: measured as drawn, not counted.
        #expect(lines.first { $0.node.id == 19 }?.plainWidth(picked: false) == nil)
        #expect(lines.first { $0.node.id == 21 }?.plainWidth(picked: false) == nil)
    }

    /// Every row's height of an open X-sized tree, as the table asks for it
    /// on a reload: counted, so far under a frame.
    @Test func everyRowsWidthOfTwentyThousandNodesIsCountedQuickly() {
        let (root, _, _) = xLike()
        let open = Set(DevTreeKeys.subtree(1, in: DevTreeIndex(root)))
        let lines = DevTreeLine.lines(root, open: open)
        var counted = 0
        let took = ms { for line in lines where line.plainWidth(picked: false) != nil { counted += 1 } }
        print(String(format: "DEVTREE widths of %d lines counted in %.1f ms", lines.count, took))
        #expect(counted == lines.count)
        #expect(took < 100, "widths took \(took) ms")
    }
}
