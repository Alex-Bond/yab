import Foundation
import AppKit
import Testing
@testable import Fast

@Suite(.serialized) @MainActor struct DevConsoleTests {
    @Test func headCountsOccurrencesAcrossTargetsAndClearsWithConsole() {
        let log = ConsoleLog()
        log.apply([message("error 1", level: "error"), .repeated(40),
                   message("warning", level: "warning", target: "worker"), .repeated(20, target: "worker"),
                   message("ordinary log")])
        #expect(log.messages.count == 3)
        #expect(log.counts.errors == 40)
        #expect(log.counts.warnings == 20)
        log.clearHere()
        #expect(log.counts.errors == 0)
        #expect(log.counts.warnings == 0)
        log.apply([message("next page error", level: "error")])
        #expect(log.counts.errors == 1)
        #expect(log.counts.warnings == 0)
    }
    @Test func nativeSelectableMessagesKeepCssAndLinksAfterUnicode() {
        var text = AttributedString("🙂 ")
        var styled = AttributedString("object")
        ConsoleCSS.apply("color:red;font-size:20px;font-weight:bold;font-style:italic;text-decoration:underline", to: &styled)
        styled.link = URL(string: "yab-console://value/0")
        text += styled
        let native = ConsoleCSS.nativeText(text)
        #expect(native.string == "🙂 object")
        #expect(styled.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
        #expect(styled.inlinePresentationIntent?.contains(.emphasized) == true)
        #expect((native.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize == 20)
        #expect((native.attribute(.foregroundColor, at: 3, effectiveRange: nil) as? NSColor)?.usingColorSpace(.deviceRGB)?.redComponent == 1)
        #expect((native.attribute(.link, at: 3, effectiveRange: nil) as? URL)?.scheme == "yab-console")
        #expect(native.attribute(.underlineStyle, at: 3, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
    }
    private func message(_ words: String, type: String = "log", level: String = "log", target: String = "", values: [[String: Any]] = []) -> ConsoleLog.Item {
        ConsoleLog.parse(["t": "m", "tg": target, "src": "console-api", "lv": level, "ty": type, "x": words,
                          "u": "http://localhost/app.js", "l": 7, "p": values])
    }

    @Test func nestedCollapsedGroupsAndRepeatsKeepTheirIdentity() {
        let log = ConsoleLog()
        log.apply([message("outer", type: "startGroup"), message("inner", type: "startGroupCollapsed"),
                   message("inside"), .repeated(5), message("", type: "endGroup"), message("after inner"),
                   message("", type: "endGroup"), message("outside")])
        #expect(log.messages.count == 5)
        let outer = log.messages[0].id, inner = log.messages[1].id
        #expect(log.messages[2].groups == [outer, inner])
        #expect(log.messages[2].count == 5)
        #expect(log.messages[3].groups == [outer])
        #expect(log.messages[4].groups.isEmpty)
        #expect(log.shut == [inner])
        let panel = ConsolePanel()
        #expect(!panel.shown(log).contains { $0.text == "inside" })
        log.shut.remove(inner)
        #expect(panel.shown(log).contains { $0.text == "inside" })
    }

    @Test func workerGroupsAndRepeatCountsStayWithTheirTarget() {
        let log = ConsoleLog()
        log.apply([message("page group", type: "startGroup"), message("page"),
                   message("worker group", type: "startGroup", target: "worker"),
                   message("worker", target: "worker"), .repeated(4), .repeated(3, target: "worker"),
                   message("", type: "endGroup", target: "worker"), message("worker outside", target: "worker"),
                   message("page inside")])
        #expect(log.messages[1].count == 4)
        #expect(log.messages[3].count == 3)
        #expect(log.messages[3].groups == [log.messages[2].id])
        #expect(log.messages[4].groups.isEmpty)
        #expect(log.messages[5].groups == [log.messages[0].id])
    }

    @Test func navigationKeepsOldMessagesButClosesTheirGroups() {
        let prefs = ConsolePrefs.shared, previous = prefs.keepLog
        defer { prefs.keepLog = previous }
        prefs.keepLog = true
        let log = ConsoleLog()
        log.apply([message("group", type: "startGroupCollapsed"), message("old"),
                   .cleared("main-frame-navigation", "http://localhost/next"), message("new")])
        #expect(log.messages.count == 4)
        #expect(log.messages[2].kind == .navigated)
        #expect(log.messages.last?.groups.isEmpty == true)
        log.apply([.cleared("console-api", "")])
        #expect(log.messages.isEmpty)
        #expect(log.shut.isEmpty)
    }

    @Test func repeatsDoNotOverwritePromptResults() {
        let log = ConsoleLog()
        log.apply([message("page")])
        _ = log.command("1 + 2")
        log.answer(ConsoleValue(json: ["ty": "number", "v": 3]), thrown: false, saved: 1)
        log.apply([.repeated(4)])
        #expect(log.messages[0].count == 4)
        #expect(log.messages[2].count == 1)
        #expect(log.messages[2].saved == 1)
    }

    @Test func filtersCombineWordsRegexAndSourceExclusions() {
        let log = ConsoleLog()
        log.apply([message("Error: widget42 failed", level: "error")])
        let m = log.messages[0]
        #expect(ConsoleFilter(text: "widget -timeout url:app.js source:console-api context:top").admits(m) { _ in "top" })
        #expect(ConsoleFilter(text: "/widget[0-9]+/").admits(m) { _ in "top" })
        #expect(!ConsoleFilter(text: "-url:app.js").admits(m) { _ in "top" })
        #expect(!ConsoleFilter(text: "context:worker").admits(m) { _ in "top" })
    }

    @Test func substitutionsPreserveCssWithoutPrintingIt() {
        let log = ConsoleLog()
        log.apply([message("", values: [["ty": "string", "v": "%cHello%c %s %d %f %%"],
                                         ["ty": "string", "v": "color: red"], ["ty": "string", "v": ""],
                                         ["ty": "string", "v": "Bob"], ["ty": "number", "v": 42.9],
                                         ["ty": "number", "v": 1.5]])])
        #expect(log.messages[0].words == "Hello Bob 42 1.5 %")
        #expect(ConsoleFormat.parts(log.messages[0]).first == .text("Hello", css: "color: red"))
        #expect(ConsoleFormat.plainValue(ConsoleValue(json: ["ty": "boolean", "v": true]), top: false) == "true")
        #expect(ConsoleFormat.plainValue(ConsoleValue(json: ["ty": "number", "v": 1]), top: false) == "1")
    }

    @Test func eagerPreviewNeverReadsGettersCallsOrCoercibleObjects() {
        for expression in ["2 * 21", "(1 + 2) / 3", "true && false", "'hello' + 'world'", "1e3 + 0xff"] {
            #expect(ConsoleEager.safe(expression), Comment(rawValue: expression))
        }
        for expression in ["window.counter", "obj.getter", "proxy['name']", "obj + 1", "Math.abs(-1)",
                           "JSON.stringify(obj)", "fetch('/')", "window.counter = 5", "x++", "new Date()",
                           "`hi ${run()}`", "({get value() { return fetch('/') }})", "(()=>run())()",
                           "'literal'.toString()", "2; run()", "1 /* comment */ + 2", "/0/ + 1", "(/0/ + 1)", "1 / /0/"] {
            #expect(!ConsoleEager.safe(expression), Comment(rawValue: expression))
        }
    }

    @Test func staleLiveUpdatesAreIgnored() {
        let log = ConsoleLog()
        log.addLive("counter")
        let value = ConsoleValue(json: ["ty": "number", "v": 42])
        log.apply([.live(-1, value), .live(3, value)])
        #expect(log.live[0].value == nil)
        log.apply([.live(0, value)])
        #expect(log.live[0].value == value)
        log.dropLive(log.live[0].id)
        log.apply([.live(0, value)])
        #expect(log.live.isEmpty)
    }
    @Test func nodeDescriptionsKeepExistingMarkupAndSpecialNodes() {
        #expect(ConsoleFormat.nodeTag("<h1 id=\"title\">") == "<h1 id=\"title\">")
        #expect(ConsoleFormat.nodeTag("h1#title.big.headline") == "<h1 id=\"title\" class=\"big headline\">")
        #expect(ConsoleFormat.nodeTag("#text") == "#text")
        #expect(ConsoleFormat.nodeTag("#document") == "#document")
    }

    @Test func resultsKeepStringQuotesAndDoNotInterpretFormatSpecifiers() {
        let log = ConsoleLog()
        log.answer(ConsoleValue(json: ["ty": "string", "v": "%cvalue"]), thrown: false, saved: 1)
        #expect(log.messages[0].words == "'%cvalue'")
    }

    @Test func separatelyShownRepeatsNeverCollideWithMessageIds() {
        let prefs = ConsolePrefs.shared, previous = prefs.groupSimilar
        defer { prefs.groupSimilar = previous }
        prefs.groupSimilar = false
        let log = ConsoleLog()
        log.apply([message("repeat"), .repeated(3), message("next")])
        let shown = ConsolePanel().shown(log)
        #expect(shown.count == 4)
        #expect(Set(shown.map(\.id)).count == shown.count)
        #expect(shown.prefix(3).allSatisfy { $0.id < 0 && $0.count == 1 })
    }

    @Test func decodedBatchesStayInWireOrderAndClearsDiscardOldWork() async throws {
        let log = ConsoleLog()
        let rows: [[String: Any]] = [["t": "m", "ty": "startGroup", "x": "group"]] +
            (0..<1000).map { ["t": "m", "ty": "log", "x": "line \($0)"] }
        let data = try JSONSerialization.data(withJSONObject: rows)
        log.hear(String(decoding: data, as: UTF8.self))
        log.hear(#"[{"t":"m","ty":"endGroup"},{"t":"m","x":"outside"}]"#)
        for _ in 0..<200 where log.messages.count < 1002 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.messages.count == 1002)
        #expect(log.messages.last?.text == "outside")
        #expect(log.messages.last?.groups.isEmpty == true)
        #expect(log.messages[1].groups == [log.messages[0].id])
        log.hear(String(decoding: data, as: UTF8.self))
        log.clearHere()
        log.hear(#"[{"t":"m","x":"fresh"}]"#)
        for _ in 0..<200 where log.messages.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.messages.map(\.text) == ["fresh"])
    }

}
