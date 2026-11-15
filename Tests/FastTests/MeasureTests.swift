import Foundation
import JavaScriptCore
import Testing
@testable import Fast

// Measure's arithmetic (Measure.math), run as the page runs it, and what
// the page tells its dock, read as the dock reads it.
struct MeasureTests {
    private func math() -> JSContext {
        let context = JSContext()!
        context.evaluateScript(Measure.math)
        return context
    }

    private func distances(_ a: [Double], _ b: [Double]) -> [(v: Double, dash: Bool)] {
        let context = math()
        let js = "JSON.stringify(MeasureMath.distances({x:\(a[0]),y:\(a[1]),w:\(a[2]),h:\(a[3])},{x:\(b[0]),y:\(b[1]),w:\(b[2]),h:\(b[3])}))"
        let text = context.evaluateScript(js)!.toString()!
        let lines = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [[String: Any]] ?? []
        return lines.map { (($0["v"] as? Double) ?? 0, ($0["dash"] as? Bool) ?? false) }
    }

    /// A box touching its container's edge says 0 there: the zero is a
    /// measurement, not nothing (the screenshot that started this: text
    /// set right against its tile's edge).
    @Test func keepsTheZeroInside() {
        let lines = distances([0, 0, 100, 20], [0, 0, 300, 100]).filter { !$0.dash }
        #expect(lines.count == 4)
        #expect(lines.contains { $0.v == 0 })
        #expect(lines.contains { $0.v == 200 })
        #expect(lines.contains { $0.v == 80 })
    }

    @Test func measuresBoxesApart() {
        let lines = distances([0, 0, 100, 20], [0, 52, 100, 20]).filter { !$0.dash }
        #expect(lines.map(\.v) == [32])
    }

    @Test func touchingBoxesSayZero() {
        let lines = distances([0, 0, 100, 20], [0, 20, 100, 20]).filter { !$0.dash }
        #expect(lines.map(\.v) == [0])
    }

    @Test func writesNumbersAsCSSDoes() {
        let context = math()
        #expect(context.evaluateScript("MeasureMath.fmt(12.34)")!.toString() == "12.3")
        #expect(context.evaluateScript("MeasureMath.fmt(-0.01)")!.toString() == "0")
        #expect(context.evaluateScript("MeasureMath.fmt(24, 16)")!.toString() == "1.5rem")
        #expect(context.evaluateScript("MeasureMath.sides(22, 22, 20, 22)")!.toString() == "22 22 20")
        #expect(context.evaluateScript("MeasureMath.sides(8, 8, 8, 8)")!.toString() == "8")
        #expect(context.evaluateScript("MeasureMath.hex('rgba(255, 0, 0, 0.5)')")!.toString() == "#ff000080")
    }

    @Test func snapsToTheNearestMark() {
        let context = math()
        let snapped = context.evaluateScript("JSON.stringify(MeasureMath.snap(103, [{at: 100, name: 'a left'}, {at: 110, name: 'b'}], 5))")!.toString()!
        #expect(snapped.contains("\"at\":100") && snapped.contains("a left"))
        let free = context.evaluateScript("JSON.stringify(MeasureMath.snap(130, [{at: 100, name: 'a'}], 5))")!.toString()!
        #expect(free.contains("\"at\":130") && free.contains("null"))
    }

    /// The whole page script is one function the page can run.
    @Test func scriptParses() {
        let context = JSContext()!
        var failed: String?
        context.exceptionHandler = { _, error in failed = error?.toString() }
        context.evaluateScript("var made = " + Measure.script + "; typeof made")
        #expect(failed == nil)
        #expect(context.evaluateScript("typeof made")!.toString() == "function")
    }

    /// The dock reads what the page tells it (the page's tellDock).
    @Test func dockReadsWhatThePageSays() throws {
        let json = """
        {"sel":{"name":"section#added","size":"732 × 270.4"},"issues":3,"showIssues":false,
         "rows":[{"l":"Padding","v":[{"t":"0","bad":true}]},{"l":"Color","v":[],"c":["#ededed","#161616"]}],
         "rules":[{"sel":".version .changes","where":"changelog.css:17","decls":[{"p":"margin-top","v":"32px","x":false,"ch":false}]}],
         "motion":[{"name":"lb-write","ms":600,"delay":250,"ease":"ease","bez":[0.25,0.1,0.25,1],"props":[["clipPath","a","b"]],"total":850,"t":850,"running":false}],
         "list":[],"pins":[{"a":"section#added","b":"h4","v":"46 above"}],"notes":[{"n":1,"text":"Inset it","mine":true}],
         "compare":null,"xray":false}
        """
        let info = try JSONDecoder().decode(MeasureInfo.self, from: Data(json.utf8))
        #expect(info.sel?.name == "section#added")
        #expect(info.issues == 3)
        #expect(info.rows.first?.v.first?.bad == true)
        #expect(info.rows.last?.c == ["#ededed", "#161616"])
        #expect(info.rules.first?.where == "changelog.css:17")
        #expect(info.motion.first?.total == 850)
        #expect(info.pins.count == 1 && info.notes.first?.text == "Inset it")
    }
}
