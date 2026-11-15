import AppKit
import Testing
import WebKit
@testable import Fast

struct SelectionCommandsTests {
    @Test @MainActor func freshProfileStartsWithFiveCommands() {
        let enabled = SelectionCommand.builtIn.filter(\.enabled).map(\.id)
        #expect(enabled == ["improve", "fix", "translate", "summarize", "explain"])
    }

    @Test @MainActor func cleansModelPreambles() {
        #expect(SelectionCommands.clean("Here is the improved version:  Hello there  ") == "Hello there")
        #expect(SelectionCommands.clean("  A direct answer\n") == "A direct answer")
    }

    @Test @MainActor func savedCommandOrderSurvivesReload() {
        let builtIns = SelectionCommand.builtIn
        var custom = SelectionCommand(id: "custom", name: "My command", prompt: "{selection}", executor: "mac")
        custom.custom = true
        var savedShorter = builtIns[2]
        savedShorter.enabled = true
        var savedImprove = builtIns[0]
        savedImprove.enabled = false
        let merged = SelectionCommands.merged([custom, savedShorter, savedImprove, savedShorter])
        #expect(Array(merged.prefix(3).map(\.id)) == ["custom", builtIns[2].id, builtIns[0].id])
        #expect(merged[1].enabled)
        #expect(!merged[2].enabled)
        #expect(merged.count == builtIns.count + 1)
    }

    @Test @MainActor func contextMenuRespectsDisabledCommands() {
        var commands = SelectionCommand.builtIn
        commands[1].enabled = false
        #expect(SelectionCommands.menuSuggestions(commands).map(\.id) == ["improve", "translate"])
    }

    @Test @MainActor func unchangedResultLeavesPageUntouched() async throws {
        let tab = Fast.Tab(bench: true)
        defer { tab.close() }
        tab.page.navigate(html:"<textarea id=body>Keep this text</textarea>", base: nil)
        for _ in 0..<100 {
            if (try? await tab.page.run("document.getElementById('body') != null")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = try await tab.page.run("(() => { const e = document.getElementById('body'); e.focus(); e.select(); return true })()")
        let commands = SelectionCommands()
        var read: SelectionSnapshot?
        commands.peek(on: tab) { read = $0 }
        for _ in 0..<100 where read == nil { try await Task.sleep(for: .milliseconds(10)) }
        let snap = try #require(read)
        commands.run(SelectionCommand(id: "same", name: "Same", prompt: "", executor: "local"), on: tab, snapshot: snap)
        for _ in 0..<100 where commands.stage != .failed { try await Task.sleep(for: .milliseconds(10)) }
        #expect(commands.stage == .failed)
        #expect(commands.noChange)
        #expect(commands.error == "Nothing to change")
        let text = try await tab.page.run("document.getElementById('body').value") as? String
        #expect(text == "Keep this text")
    }

    @Test @MainActor func selectedFieldIsOnlyChangedAfterApply() async throws {
        let web = await AgentKeysTests.page("<textarea id=body>hey, sorry for late reply</textarea>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('body'); e.focus(); e.setSelectionRange(0, 10); true
        """)
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(read?["text"] as? String == "hey, sorry")
        #expect(read?["editable"] as? Bool == true)
        let field = try await web.evaluateJavaScript("""
        const r = document.getElementById('body').getBoundingClientRect();
        ({width:r.width,height:r.height})
        """) as? [String: Double]
        let rect = read?["rect"] as? [String: Double]
        #expect((rect?["width"] ?? 0) < (field?["width"] ?? 0))
        #expect((rect?["height"] ?? 0) < (field?["height"] ?? 0))
        let untouched = try await web.evaluateJavaScript("document.getElementById('body').value") as? String
        #expect(untouched == "hey, sorry for late reply")
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('Hi, sorry')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "ok")
        let changed = try await web.evaluateJavaScript("document.getElementById('body').value") as? String
        #expect(changed == "Hi, sorry for late reply")
    }

    @Test @MainActor func staleSelectionIsNotReplaced() async throws {
        let web = await AgentKeysTests.page("<textarea id=body>Original text</textarea>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('body'); e.focus(); e.setSelectionRange(0, 8); true
        """)
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("document.getElementById('body').value = 'Changed text'")
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('Replacement')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "changed")
        let text = try await web.evaluateJavaScript("document.getElementById('body').value") as? String
        #expect(text == "Changed text")
    }

    @Test @MainActor func removedFieldIsNotReplaced() async throws {
        let web = await AgentKeysTests.page("<textarea id=body>Original text</textarea>")
        _ = try await web.evaluateJavaScript("const e = document.getElementById('body'); e.focus(); e.select(); true")
        _ = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("document.getElementById('body').remove()")
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('Replacement')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "gone")
    }

    @Test @MainActor func longTextareaSelectionStaysBoundedAndCopyOnly() async throws {
        let web = await AgentKeysTests.page("<textarea id=body></textarea>")
        _ = try await web.evaluateJavaScript("const e = document.getElementById('body'); e.value = 'word '.repeat(6000); e.focus(); e.select(); true")
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect((read?["text"] as? String)?.count == 20_000)
        #expect(read?["truncated"] as? Bool == true)
        #expect(read?["editable"] as? Bool == false)
        #expect(read?["preciseRect"] as? Bool == false)
        #expect(((read?["around"] as? String)?.count ?? 0) <= 1_200)
        let retained = try await web.evaluateJavaScript("window.__yabSelectionRecord === null", in: nil, contentWorld: .defaultClient) as? Bool
        #expect(retained == true)
        let unchanged = try await web.evaluateJavaScript("document.getElementById('body').value.length") as? Int
        #expect(unchanged == 30_000)
    }

    @Test @MainActor func deepTextareaUsesFieldCardWithoutSlowMirror() async throws {
        let web = await AgentKeysTests.page("<textarea id=body></textarea>")
        _ = try await web.evaluateJavaScript("const e = document.getElementById('body'); e.value = 'x'.repeat(12000) + 'choice'; e.focus(); e.setSelectionRange(12000, 12006); true")
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(read?["text"] as? String == "choice")
        #expect(read?["editable"] as? Bool == true)
        #expect(read?["preciseRect"] as? Bool == false)
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('answer')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "ok")
        let suffix = try await web.evaluateJavaScript("document.getElementById('body').value.slice(-6)") as? String
        #expect(suffix == "answer")
    }

    @Test @MainActor func richEditorUsesTheSavedRange() async throws {
        let web = await AgentKeysTests.page("<div id=body contenteditable=true>Hello old world</div>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('body'); e.focus();
        const r = document.createRange(); r.setStart(e.firstChild, 6); r.setEnd(e.firstChild, 9);
        const s = document.getSelection(); s.removeAllRanges(); s.addRange(r); true
        """)
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(read?["text"] as? String == "old")
        #expect(read?["editable"] as? Bool == true)
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('new')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "ok")
        let text = try await web.evaluateJavaScript("document.getElementById('body').textContent") as? String
        #expect(text == "Hello new world")
    }

    @Test @MainActor func passwordFieldDoesNotExposeItsSelection() async throws {
        let web = await AgentKeysTests.page("<input id=secret type=password value=topsecret>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('secret'); e.focus(); e.setSelectionRange(0, 9); true
        """)
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient)
        #expect(read is NSNull)
    }

    @Test @MainActor func pageTextCanBeReadButNotReplaced() async throws {
        let web = await AgentKeysTests.page("<p id=words>The original page text</p>")
        _ = try await web.evaluateJavaScript("""
        const e = document.getElementById('words').firstChild;
        const r = document.createRange(); r.setStart(e, 4); r.setEnd(e, 12);
        const s = document.getSelection(); s.removeAllRanges(); s.addRange(r); true
        """)
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(read?["text"] as? String == "original")
        #expect(read?["editable"] as? Bool == false)
        let applied = try await web.evaluateJavaScript("window.__yabApplySelection('changed')", in: nil, contentWorld: .defaultClient) as? String
        #expect(applied == "failed")
        let text = try await web.evaluateJavaScript("document.getElementById('words').textContent") as? String
        #expect(text == "The original page text")
    }

    /// A canvas that can't give a pixel, as when the GPU process is busy or
    /// coming back (getImageData throws InvalidStateError): the words are
    /// still read, with the field's colors and the page dark under it.
    @Test @MainActor func colorsAreReadWhenNoPixelCanBe() async throws {
        let web = await AgentKeysTests.page("<div style='background:#123456;color:rgb(250 240 230)'><textarea id=body style='background:transparent;color:inherit'>dark field</textarea></div>")
        _ = try await web.evaluateJavaScript("""
        CanvasRenderingContext2D.prototype.getImageData = function () { throw new DOMException('busy', 'InvalidStateError') }; true
        """, in: nil, contentWorld: .defaultClient)
        _ = try await web.evaluateJavaScript("const e = document.getElementById('body'); e.focus(); e.setSelectionRange(0, 4); true")
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        #expect(read?["text"] as? String == "dark")
        #expect(read?["foreground"] as? String == "faf0e6")
        #expect(read?["ground"] as? String == "123456")
        #expect(read?["dark"] as? Bool == true)
        let colors = try await web.evaluateJavaScript("""
        (function () {
        \(DropFrame.ground)
        return [yabColor('rgba(0, 0, 0, 0)'), yabColor('rgb(10 20 30 / 50%)'), yabColor('rgba(255, 255, 255, 0.5)'), yabColor('oklch(0.2 0.1 200)')];
        })()
        """, in: nil, contentWorld: .defaultClient) as? [Any]
        #expect(colors?[0] as? [Int] == [0, 0, 0, 0])
        #expect(colors?[1] as? [Int] == [10, 20, 30, 128])
        #expect(colors?[2] as? [Int] == [255, 255, 255, 128])
        #expect(colors?[3] is NSNull)
    }

    @Test @MainActor func rewritesGoInPlaceAndAnswersOnACard() {
        let built = Dictionary(uniqueKeysWithValues: SelectionCommand.builtIn.map { ($0.id, $0) })
        for id in ["improve", "fix", "shorter", "longer", "formal", "friendly", "translate"] {
            #expect(SelectionCommands.rewrites(built[id], editable: true), "\(id)")
            #expect(SelectionCommands.rewrites(built[id], editable: false), "\(id) on page text")
        }
        for id in ["summarize", "explain", "define", "explain-code", "find-bugs", "quote", "calendar", "map"] {
            #expect(!SelectionCommands.rewrites(built[id], editable: true), "\(id)")
        }
        var custom = SelectionCommand(id: "c", name: "Pirate", prompt: "Talk like a pirate", executor: "mac", custom: true)
        #expect(SelectionCommands.rewrites(custom, editable: true))
        #expect(!SelectionCommands.rewrites(custom, editable: false))
        custom.result = "inPlace"
        #expect(SelectionCommands.rewrites(custom, editable: false))
        custom.result = "beside"
        #expect(!SelectionCommands.rewrites(custom, editable: true))
        custom.result = "draft"
        #expect(!SelectionCommands.rewrites(custom, editable: true))
        #expect(!SelectionCommands.rewrites(SelectionCommand(id: "ask", name: "Ask", prompt: "why", executor: "agent"), editable: true))
    }

    @Test @MainActor func inkBarStandsUnderTheLastLineAndNeverOnIt() {
        let room = CGSize(width: 900, height: 700)
        let bar = CGSize(width: 320, height: 40)
        // Under the end of the last line, its trailing edge just past it.
        let under = SelectionInk.barOrigin(end: CGPoint(x: 600, y: 300), foot: 300, top: 240, bar: bar, room: room)
        #expect(under == CGPoint(x: 296, y: 308))
        // A short last line: kept in from the window's left edge.
        #expect(SelectionInk.barOrigin(end: CGPoint(x: 90, y: 300), foot: 300, top: 240, bar: bar, room: room).x == 12)
        // Near the window's right edge: kept in from it.
        #expect(SelectionInk.barOrigin(end: CGPoint(x: 895, y: 300), foot: 300, top: 240, bar: bar, room: room).x == 568) // 900 - 320 - 12
        // Words in a field: kept inside the field's left edge.
        #expect(SelectionInk.barOrigin(end: CGPoint(x: 300, y: 300), foot: 300, top: 240, bar: bar, room: room, left: 120).x == 120)
        // Under the original when it is the longer of the two.
        #expect(SelectionInk.barOrigin(end: CGPoint(x: 600, y: 300), foot: 340, top: 240, bar: bar, room: room).y == 348)
        // No room under it: above the selection, clear of the words.
        let above = SelectionInk.barOrigin(end: CGPoint(x: 600, y: 680), foot: 680, top: 620, bar: bar, room: room)
        #expect(above.y == 572) // 620 - 8 - 40
        #expect(above.y + bar.height <= 620)
    }

    @Test @MainActor func inkWrapsWhereTheFieldDoes() async throws {
        let web = await AgentKeysTests.page("<textarea id=body style='box-sizing:border-box;width:500px;padding:10px;border:1px solid #ccc;font:15px -apple-system'>hey, sorry for late reply</textarea>")
        _ = try await web.evaluateJavaScript("const e = document.getElementById('body'); e.focus(); e.setSelectionRange(0, 4); true")
        let read = try await web.evaluateJavaScript(SelectionCommands.readScript, in: nil, contentWorld: .defaultClient) as? [String: Any]
        let box = read?["box"] as? [String: Double]
        let rect = read?["rect"] as? [String: Double]
        #expect(box?["width"] == 478) // 500 - 20 - 2
        // The selection's own rect is four letters wide; the block is the field's.
        #expect((rect?["width"] ?? 0) < 100)
        #expect((box?["x"] ?? 0) <= (rect?["x"] ?? 0))
    }
}
