import Foundation
import Testing
@testable import Fast

// Developer Tools kept over a tab switch (DevReturn.swift): the inspector
// left comes up anew with new numbers, and what the person had is found
// again by place, not shown twice, not lost.
@Suite(.serialized) @MainActor struct DevReturnTests {
    private func node(_ id: Int, _ tag: String, _ children: [DevDOMNode] = [], type: Int = 1) -> DevDOMNode {
        DevDOMNode(id: id, type: type, label: "<\(tag)>", count: children.count, children: children, name: tag)
    }

    /// A page as one inspector numbers it, from `base`.
    private func page(_ base: Int, extra: Bool = false) -> DevDOMNode {
        var main = [node(base + 5, "h1"), node(base + 6, "p")]
        if extra { main.insert(node(base + 9, "aside"), at: 0) }
        return node(base, "#document", [
            node(base + 1, "html", [
                node(base + 2, "head"),
                node(base + 3, "body", [node(base + 4, "main", main), node(base + 7, "footer", [node(base + 8, "a")])]),
            ]),
        ], type: 9)
    }

    @Test func pathsLeadFromTheDocumentToEachNode() {
        let tree = page(1)
        let paths = tree.paths(to: [6, 9])
        // h1 in main in body, a in footer in body.
        #expect(paths[6] == [0, 1, 0, 0])
        #expect(paths[9] == [0, 1, 1, 0])
    }

    @Test func aTreeNumberedAnewIsFoundAgainByPlace() {
        let map = DevDOMNode.matched(page(1), page(101))
        #expect(map[1] == 101 && map[6] == 106 && map[9] == 109)
        // The page added a node while it was away: the rest still found.
        let moved = DevDOMNode.matched(page(1), page(101, extra: true))
        #expect(moved[5] == 105 && moved[6] == 106 && moved[9] == 109)
    }

    @Test func openNodesSelectionAndTopRowSurviveAReturn() {
        let model = DevWorkbench()
        model.root = page(1)
        model.expanded = [1, 2, 4, 5, 8]
        model.selectedNode = 6
        model.elementsTop = "o5"
        model.domBreaks = [DevDOMBreak(node: 9, type: "subtree-modified", label: "a")]
        model.reconnected()
        // The old tree stays shown until the new inspector's is in.
        #expect(model.root?.id == 1 && model.keptTree != nil)
        let asked = model.keptPaths(model.keptTree!)
        let open = asked.compactMap { $0["i"] as? [Int] }
        // The selected h1, the open footer; WebKit's own path to the h1,
        // its children not wanted, the footer's wanted.
        #expect(open.contains([0, 1, 0, 0]) && open.contains([0, 1, 1]))
        #expect(asked.contains { $0["p"] as? String == "0,HTML,1,BODY,0,MAIN,0,H1" && $0["k"] as? Bool == false })
        #expect(asked.contains { $0["p"] as? String == "0,HTML,1,BODY,1,FOOTER" && $0["k"] as? Bool == true })
        let data = try! JSONEncoder().encode(page(101))
        #expect(model.loadTree(try! JSONSerialization.jsonObject(with: data)))
        #expect(model.keptTree == nil && model.root?.id == 101)
        #expect(model.expanded == [101, 102, 104, 105, 108])
        #expect(model.selectedNode == 106)
        #expect(model.elementsTop == "o105")
        #expect(model.domBreaks.first?.node == 109)
    }

    @Test func aNewDocumentStillStartsFresh() {
        let model = DevWorkbench()
        model.root = page(1)
        model.expanded = [1, 2, 4]
        model.selectedNode = 6
        model.connected()
        let data = try! JSONEncoder().encode(page(101))
        #expect(!model.loadTree(try! JSONSerialization.jsonObject(with: data)))
        #expect(model.selectedNode == 0)
    }

    private func line(_ words: String, at time: Double, type: String = "log") -> ConsoleLog.Item {
        ConsoleLog.parse(["t": "m", "tg": "", "src": "console-api", "lv": "log", "ty": type, "x": words, "ts": time,
                          "u": "http://localhost/app.js", "l": 7])
    }

    @Test func consoleKeepsItsLinesAndAnswersAndTakesTheReplayOnce() {
        let log = ConsoleLog()
        log.apply([line("one", at: 1), line("two", at: 2)])
        _ = log.command("1 + 1")
        log.answer(ConsoleValue(type: "number", description: "2"), thrown: false, saved: -1)
        let before = log.messages.map(\.id)
        log.reconnected()
        // WebKit hands over again what the page said, then the page says more.
        log.apply([line("one", at: 1), line("two", at: 2), line("three", at: 3)])
        #expect(Array(log.messages.map(\.id).prefix(4)) == before)
        #expect(log.messages.map(\.text).filter { $0 == "one" }.count == 1)
        #expect(log.messages.last?.text == "three")
        #expect(log.messages.contains { $0.kind == .command && $0.text == "1 + 1" })
        // A new page after that clears as before.
        log.connected()
        #expect(log.messages.isEmpty || ConsolePrefs.shared.keepLog)
    }

    private func batch(_ object: [String: Any]) -> NetBatch {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return NetBatch.parse(String(data: data, encoding: .utf8)!)!
    }

    @Test func networkKeepsItsRowsAndTakesTheResourceTreeOnce() {
        let log = NetLog()
        log.apply(batch(["r": [
            ["i": 1, "u": "https://a.test/", "m": "GET", "y": "document", "mn": true, "ld": "L1", "ts": 100.0, "en": 100.5, "dn": true, "st": 200],
            ["i": 2, "u": "https://a.test/app.js", "m": "GET", "y": "script", "ld": "L1", "ts": 100.1, "en": 100.3, "dn": true, "st": 200],
        ]]))
        log.flush()
        let before = log.rows.map(\.id)
        log.reconnected()
        // The new inspector reads the frame: the same two, without timings,
        // its main frame said as a new page of the same loader; then a
        // request the page makes now.
        log.apply(batch(["nav": "L1", "r": [
            ["i": 1, "u": "https://a.test/", "m": "GET", "y": "document", "mn": true, "ld": "L1", "dn": true, "st": 200],
            ["i": 2, "u": "https://a.test/app.js", "m": "GET", "y": "script", "ld": "L1", "dn": true, "st": 200],
            ["i": 3, "u": "https://a.test/api", "m": "GET", "y": "fetch", "ld": "L1", "ts": 200.0, "dn": false],
        ]]))
        log.flush()
        #expect(Array(log.rows.map(\.id).prefix(2)) == before)
        #expect(log.rows.map(\.url) == ["https://a.test/", "https://a.test/app.js", "https://a.test/api"])
        #expect(log.rows.first?.resource.sent == 100.0)
    }
}
