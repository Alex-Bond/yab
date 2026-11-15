import AppKit
import Foundation
import Testing
@testable import Fast

@Suite(.serialized) @MainActor struct DevWorkbenchTests {
    @Test func dictionariesAndRemoteObjectsUseDifferentSerialization() {
        #expect(DevWorkbench.string(["url": "https://example.test", "items": [1, 2]]).contains("example.test"))
        #expect(DevWorkbench.string(["type": "number", "value": 7]) == "7")
        #expect(DevWorkbench.string(["type": "object", "description": "Window"]) == "Window")
    }
    @Test func fieldEditorKeepsDeveloperToolShortcutOwnership() {
        let owner = DevTestKeyOwner()
        let field = DevTestFieldDelegate()
        owner.addSubview(field)
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.delegate = field
        #expect(DevKeys.contains(editor))
        field.removeFromSuperview()
        #expect(!DevKeys.contains(editor))
    }
    @Test func navigationInvalidatesOnlyDocumentBoundState() {
        let model = DevWorkbench()
        model.root = DevDOMNode(id: 1, type: 9, label: "document", count: 1, children: [])
        model.selectedNode = 2; model.expanded = [1, 2]
        model.trace = [DevTraceEvent(id: 0, name: "Layout", start: 1, end: 2, depth: 0, data: "")]
        model.hear(#"[{"kind":"navigation"}]"#)
        #expect(model.root == nil && model.selectedNode == 0 && model.expanded.isEmpty)
        #expect(model.trace.count == 1)
    }
    @Test func pauseCarriesTheTargetAndResumeDropsStaleRemoteObjects() {
        let model = DevWorkbench()
        model.hear(#"[{"kind":"paused","reason":"breakpoint","frames":[{"callFrameId":"f","functionName":"calculate","target":"worker-1","location":{"scriptId":"s","lineNumber":7},"scopeChain":[{"type":"local","object":{"objectId":"scope-1"}}]}]}]"#)
        #expect(model.frames.first?.target == "worker-1")
        #expect(model.frames.first?.scopes.first?.objectID == "scope-1")
        model.scopeProperties = [DevProperty(name: "value", value: "7")]
        model.hear(#"[{"kind":"resumed"}]"#)
        #expect(model.frames.isEmpty && model.scopeProperties.isEmpty && model.frameID.isEmpty)
    }
    @Test func nestedTraceUsesSecondsAndKeepsInstantEvents() {
        let model = DevWorkbench()
        model.appendTrace([["type": "FunctionCall", "startTime": 3.0, "endTime": 3.02, "children": [["type": "Layout", "startTime": 3.001, "endTime": 3.004], ["type": "TimeStamp", "startTime": 3.005]]]])
        #expect(model.trace.count == 3)
        #expect(abs(model.trace[0].duration - 20) < 0.001)
        #expect(abs(model.trace[1].duration - 3) < 0.001)
        #expect(model.trace[2].duration == 0 && model.trace[2].depth == 1)
    }
    @Test func incompleteStylesAndNonElementSelectionNeverCrash() {
        let model = DevWorkbench()
        model.loadStyles(["styles": [["selector": "element.style", "style": ["cssText": "color: red", "cssProperties": [["name": "color", "value": "red"]]]]], "accessibility": ["role": "button"]])
        #expect(model.styles.first?.styleID.isEmpty == true)
        #expect(model.accessibility.first?.value == "button")
        model.loadStyles(["styles": [], "computed": [], "accessibility": [:]])
        #expect(model.styles.isEmpty && model.computed.isEmpty && model.accessibility.isEmpty)
    }
    @Test func stylesKeepCascadeOverridesAndInheritance() {
        let model = DevWorkbench()
        model.loadStyles(["styles": [
            ["key": "s0", "selector": "p[lang=\"ru\"]", "origin": "author", "source": "http://a.test/", "line": 1, "editable": true,
             "properties": [["index": 0, "name": "font-size", "value": "1.25em", "enabled": true]]],
            ["key": "s1", "selector": "body", "origin": "author", "inheritedFrom": "body", "editable": true,
             "properties": [["index": 0, "name": "font", "value": "16px/1.6 system-ui", "longhands": [["name": "font-size", "value": "16px", "overridden": true]]],
                            ["index": 5, "name": "max-width", "value": "26em", "dim": true]]]],
            "computed": [["name": "font-size", "value": "20px", "implicit": false], ["name": "accent-color", "value": "auto", "implicit": true]],
            "from": ["font-size": ["value": "1.25em", "selector": "p[lang=\"ru\"]", "source": "http://a.test/", "line": 1, "origin": "author"]],
            "listeners": [["id": 3, "type": "click", "owner": "window", "useCapture": true, "passive": true]]])
        #expect(model.styles.map(\.id) == ["s0", "s1"])
        #expect(model.styles[0].editable && model.styles[0].line == 1)
        #expect(model.styles[1].inheritedFrom == "body")
        #expect(model.styles[1].properties[0].longhands.first?.overridden == true)
        #expect(model.styles[1].properties[1].dim && model.styles[1].properties[1].index == 5)
        #expect(model.computedSet == ["font-size"] && model.computedFrom["font-size"]?.selector == "p[lang=\"ru\"]")
        #expect(model.listenerRows.first?.marks == ["capture", "passive"])
        model.toggleLonghands("s1", 0)
        #expect(model.styles[1].properties[0].expanded)
    }
    @Test func treeLinesWriteTheDocumentAsChrome() {
        let text = DevDOMNode(id: 5, type: 3, label: "#text", count: 0, children: [], value: "Learn more")
        let link = DevDOMNode(id: 4, type: 1, label: "<a>", count: 1, children: [text], name: "a", attrs: [["href", "/x"]])
        let space = DevDOMNode(id: 6, type: 3, label: "#text", count: 0, children: [], value: "\n  ")
        let body = DevDOMNode(id: 3, type: 1, label: "<body>", count: 2, children: [link, space], name: "body", attrs: [])
        let html = DevDOMNode(id: 2, type: 1, label: "<html>", count: 1, children: [body], name: "html", attrs: [["lang", "en"]])
        let doctype = DevDOMNode(id: 7, type: 10, label: "html", count: 0, children: [], name: "html")
        let root = DevDOMNode(id: 1, type: 9, label: "#document", count: 2, children: [doctype, html], value: "http://a.test/")
        let open = DevTreeLine.lines(root, open: [2, 3])
        #expect(open.map(\.id) == ["o7", "o2", "o3", "o4", "c3", "c2"])
        #expect(String(open[0].text(picked: false).characters) == "<!DOCTYPE html>")
        #expect(String(open[3].text(picked: false).characters) == "<a href=\"/x\">Learn more</a>")
        #expect(open[3].text(picked: false).runs.contains { $0.link?.absoluteString == "http://a.test/x" })
        let shut = DevTreeLine.lines(root, open: [])
        #expect(shut.map(\.id) == ["o7", "o2"])
        #expect(String(shut[1].text(picked: true).characters).hasSuffix("</html>  == $0"))
        #expect(DevTreeLine.crumb(DevDOMNode(id: 9, type: 1, label: "", count: 0, children: [], name: "div", attrs: [["id", "main"], ["class", "wide tall"]])) == "div#main.wide")
        #expect(DevStyle.place("http://a.test/", line: 1, page: URL(string: "http://a.test/")) == "(index):1")
        #expect(DevStyle.place("http://a.test/css/site.css", line: 12, page: URL(string: "http://a.test/")) == "site.css:12")
    }
    @Test func nativePanelsNeverAliasWebKitTabs() {
        for tab in [DevTab.elements, .console, .sources, .network, .performance, .memory, .application, .audit] { #expect(!tab.pane.isWebKit) }
    }
    @Test func malformedHeapCannotStartGraphTraversal() async {
        let error = await withCheckedContinuation { continuation in
            DevHeapEngine().read(#"{"nodes":[0,0,0,0,1,20,0,0],"nodeClassNames":["Object"],"edges":[1,999,0,0],"edgeTypes":["Property"],"edgeNames":["bad"]}"#) { _, error in continuation.resume(returning: error) }
        }
        #expect(error?.contains("Invalid") == true)
    }
    @Test func retainedSizesIncludeTheLastNodeAndSharedChildrenHaveTheCorrectDominator() async {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let engine = DevHeapEngine(scriptURL: root.appendingPathComponent("Resources/DevTools/heap-snapshot.js"))
        let text = #"{"version":3,"nodes":[0,0,0,0,1,16,1,2,2,32,1,2,3,8,2,0],"nodeClassNames":["<root>","Object","String"],"edges":[0,1,0,0,1,2,0,1,2,3,0,2],"edgeTypes":["Property"],"edgeNames":["global","child","text"]}"#
        let result = await withCheckedContinuation { continuation in
            engine.read(text, method: "nodeWithIdentifier", arguments: [1]) { value, error in continuation.resume(returning: (value, error)) }
        }
        #expect(result.1 == nil)
        #expect(result.0?["retainedSize"] as? Int == 56)
    }

    @Test func bottomUpDoesNotDoubleCountOverlappingChildren() {
        let model = DevWorkbench()
        model.appendTrace([["type": "FunctionCall", "startTime": 1.0, "endTime": 1.02, "children": [["type": "Layout", "startTime": 1.002, "endTime": 1.012], ["type": "Paint", "startTime": 1.007, "endTime": 1.017]]]])
        #expect(abs(model.trace[0].selfDuration - 5) < 0.001)
    }

    @Test func chromeTraceExportPreservesTimeUnitsAndCanBeImported() {
        let model = DevWorkbench()
        model.appendTrace([["type": "Layout", "startTime": 2.0, "endTime": 2.012, "data": ["nodeId": 7]]])
        let text = DevTraceCodec.export(model)
        let document = DevWorkbench.parse(text) as? [String: Any] ?? [:]
        let event = (document["traceEvents"] as? [[String: Any]])?.first
        #expect(event?["ts"] as? Double == 2_000_000)
        #expect(abs((event?["dur"] as? Double ?? 0) - 12_000) < 0.001)
        #expect(DevTraceCodec.records(document)?.count == 1)
    }
    @Test func symbolNavigationSkipsCommentedFunctions() {
        let symbols = DevSourceSymbols.symbols("// function fake() {}\nexport function real() {}\nconst arrow = (a) => a + 1\n")
        #expect(symbols.map(\.name) == ["real", "arrow"])
        #expect(symbols.map(\.line) == [1, 2])
    }

    @Test func recorderRoundTripKeepsWaitViewportAndKeySelectors() throws {
        let recorder = Recorder()
        try recorder.importJSON(##"{"title":"Checkout","steps":[{"type":"setViewport","width":800,"height":600},{"type":"waitForElement","selectors":[["#ready"]],"timeout":9000},{"type":"keyDown","key":"Enter","selectors":[["#name"]]},{"type":"keyUp","key":"Enter"}]}"##)
        #expect(recorder.steps.count == 3)
        #expect(recorder.steps[0].width == 800)
        #expect(recorder.steps[1].timeout == 9000)
        #expect(recorder.steps[2].selector == "#name")
        let imported = Recorder()
        try imported.importJSON(recorder.chromeJSON(title: "Checkout"))
        #expect(imported.steps.map(\.kind) == recorder.steps.map(\.kind))
        #expect(imported.steps[2].selector == "#name")
    }
    @Test func recorderRejectsUnsupportedStepsWithoutLosingTheCurrentRecording() throws {
        let recorder = Recorder()
        try recorder.importJSON(#"{"steps":[{"type":"navigate","url":"https://example.test"}]}"#)
        #expect(throws: Recorder.ImportFailure.self) { try recorder.importJSON(#"{"steps":[{"type":"customStep"}]}"#) }
        #expect(recorder.steps.count == 1 && recorder.steps[0].kind == .navigate)
    }
    @Test func recorderRoundTripKeepsClickNavigationAssertions() throws {
        let recorder = Recorder()
        try recorder.importJSON(##"{"steps":[{"type":"click","selectors":[["#next"]],"assertedEvents":[{"type":"navigation","url":"https://example.test/next"}]}]}"##)
        let imported = Recorder()
        try imported.importJSON(recorder.chromeJSON(title: "Flow"))
        #expect(imported.steps.first?.navigates == true)
        #expect(imported.steps.first?.url == "https://example.test/next")
    }
    @Test func recorderImportNeverKeepsPasswordValuesOrStartsReplay() throws {
        let recorder = Recorder()
        try recorder.importJSON(#"{"steps":[{"type":"change","selectors":[["input[type=password]"]],"value":"must-not-be-kept"}]}"#)
        #expect(recorder.steps[0].secret && recorder.steps[0].value.isEmpty)
        #expect(!recorder.recording && recorder.playing == nil)
        #expect(!recorder.chromeJSON(title: "Flow").contains("must-not-be-kept"))
    }

}

@MainActor private final class DevTestKeyOwner: NSView, DevKeyTarget {}
@MainActor private final class DevTestFieldDelegate: NSView, NSTextViewDelegate {}
