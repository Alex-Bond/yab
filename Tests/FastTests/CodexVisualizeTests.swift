import Foundation
import Testing
@testable import Fast

/// Codex's visualize markers (CodexVisualize): cut out of its words, a
/// widget in their place, and the fragment's page built as Codex's plugin
/// builds it (its scripts/render.py).
@MainActor
struct CodexVisualizeTests {
    static let path = "/Users/x/.codex/visualizations/2026/10/06/01a112a4/google-meet-pip-states.html"
    static func marker(_ name: String, _ json: String) -> String { "\u{E200}" + name + "\u{E202}" + json + "\u{E201}" }
    static let visualize = marker("visualize", #"{"path":"\#(path)","title":"Google Meet PiP · 20 states"}"#)
    /// As the real answer has it (trimmed): words, a picture, the marker last.
    static let answer = "The original is from [Google's demo](https://example.com). Below is a switcher for 20 states.\n\n" + visualize

    // MARK: parsing

    @Test func wordsBeforeAndAfterStayWords() {
        let pieces = CodexVisualize.pieces("Before\n\n" + Self.visualize + "\n\nAfter")
        #expect(pieces.count == 3)
        #expect(pieces[0] == .words("Before\n\n"))
        #expect(pieces[2] == .words("\n\nAfter"))
        guard case .entity(let entity) = pieces[1] else { Issue.record("no entity"); return }
        #expect(entity.name == "visualize")
        #expect(entity.arguments?["path"] == Self.path)
        #expect(entity.arguments?["title"] == "Google Meet PiP · 20 states")
    }

    @Test func severalMarkersEachAWidgetInPlace() {
        let second = Self.marker("visualize", #"{"path":"/tmp/visualizations/b-chart.html","mode":"wide"}"#)
        let steps = CodexVisualize.steps("One" + Self.visualize + "Two" + second + "Three", id: "msg", state: .done) { $0 }
        #expect(steps.map(\.kind) == [.message, .widget, .message, .widget, .message])
        #expect(steps.map(\.id) == ["msg", "msg.1", "msg.2", "msg.3", "msg.4"])
        #expect(steps[1].extra?["widgetFile"] == Self.path)
        #expect(steps[1].extra?["widgetKit"] == "codex")
        #expect(steps[1].extra?["widgetTitle"] == "Google Meet PiP · 20 states")
        // No title given: the file's name, as render.py makes one.
        #expect(steps[3].extra?["widgetTitle"] == "B Chart")
        #expect(steps[3].extra?["widgetMode"] == "wide")
        #expect(steps.allSatisfy { !CodexVisualize.marked($0.text) })
    }

    @Test func unknownNamesAndBrokenArgumentsLeaveNothing() {
        let cite = Self.marker("cite", "turn2search0")
        let other = Self.marker("entity", #"{"title":"A place"}"#)
        let broken = Self.marker("visualize", #"{"path": "/tmp/a.html""#)
        let noPath = Self.marker("visualize", #"{"title":"Nothing"}"#)
        let text = "Read" + cite + " this" + other + broken + noPath + "."
        let steps = CodexVisualize.steps(text, id: "m", state: .done) { $0 }
        #expect(steps.count == 1)
        #expect(steps.first?.text == "Read this.")
        #expect(CodexVisualize.stripped(text) == "Read this.")
        // Broken JSON reads as no arguments at all.
        guard case .entity(let entity) = CodexVisualize.pieces(broken).first else { Issue.record("no entity"); return }
        #expect(entity.arguments == nil)
    }

    @Test func aMarkerStillComingInAndStrayCharactersNeverShow() {
        #expect(CodexVisualize.stripped("Here it is\n\n\u{E200}visualize\u{E202}{\"pa") == "Here it is\n\n")
        #expect(CodexVisualize.stripped("a\u{E201}b\u{E202}c") == "abc")
        #expect(CodexVisualize.stripped("plain") == "plain")
        #expect(CodexVisualize.pieces("") == [])
    }

    @Test func onlyAMarkerIsAWidgetUnderTheMessagesID() {
        let steps = CodexVisualize.steps(Self.visualize, id: "msg", state: .done) { $0.isEmpty ? nil : $0 }
        #expect(steps.count == 1)
        #expect(steps.first?.kind == .widget)
        #expect(steps.first?.id == "msg")
    }

    @Test func liveAgentMessageEndsInWordsAndAWidget() {
        let started = ChatItem.codexSteps(["type": "agentMessage", "id": "m", "text": ""], done: false)
        #expect(started.map(\.kind) == [.message])
        let done = ChatItem.codexSteps(["type": "agentMessage", "id": "m", "text": Self.answer], done: true)
        #expect(done.map(\.kind) == [.message, .widget])
        #expect(done.first?.id == "m")
        #expect(done.allSatisfy { !CodexVisualize.marked($0.text) })
        // Only a marker of another kind: the streamed words give way to none.
        let other = ChatItem.codexSteps(["type": "agentMessage", "id": "m", "text": Self.marker("cite", "x")], done: true)
        #expect(other.count == 1)
        #expect(other.first?.text == "")
    }

    // MARK: the page

    static let kit = CodexVisualize.Kit(
        stylesheet: ":root{--kit:1}", inner: "<div id=kit-before></div>" + CodexVisualize.placeholder + "<script>kitAfter()</script>",
        bridge: "window.bridged=1;// </script> inside", shell: "window.pluginShell=1;", calendar: "customElements.define('viz-calendar',class{})")

    @Test func documentInlinesTheKitAndTheFragment() {
        let fragment = "<div id=\"pip\"><button>Next</button></div>"
        let page = CodexVisualize.document(fragment, title: "Meet <PiP>", kit: Self.kit, state: #"{"privateContent":{"at":3}}"#)
        // The shell under the plugin's policy, Yab's shell talking to the bridge.
        #expect(page.contains("content=\"\(CodexVisualize.shellPolicy)\""))
        #expect(page.contains("frame-src 'self'"))
        #expect(page.contains("sandbox=\"allow-scripts\""))
        #expect(page.contains("messageHandlers.\(ChatWidgetPage.handler)"))
        #expect(page.contains("codex-visualization-initialize"))
        #expect(!page.contains("window.pluginShell"))
        #expect(page.contains("<title>Meet &lt;PiP&gt;</title>"))
        // The inner frame, escaped into srcdoc: its own policy, the kit, the fragment in the kit's place.
        let frame = page.components(separatedBy: "data-srcdoc=\"").last?.components(separatedBy: "\"></iframe>").first ?? ""
        #expect(frame.contains(CodexVisualize.escaped("content=\"\(CodexVisualize.framePolicy)\"")))
        #expect(frame.contains(CodexVisualize.escaped(":root{--kit:1}")))
        #expect(frame.contains(CodexVisualize.escaped("<div id=kit-before></div>" + fragment + "<script>kitAfter()</script>")))
        #expect(frame.contains(CodexVisualize.escaped("window.bridged=1;// <\\/script> inside")))
        #expect(!frame.contains(CodexVisualize.escaped(CodexVisualize.placeholder)))
        // Yab's colors under the kit's host names; the chat's ground shows through.
        #expect(frame.contains("--color-text-primary:light-dark("))
        #expect(frame.contains("background-color:transparent!important"))
        // What it kept, put in for its bridge.
        #expect(frame.contains("statePersistence"))
        #expect(frame.contains("privateContent"))
        #expect(!frame.contains(CodexVisualize.stateMark))
        // No calendar unless the fragment uses one.
        #expect(!frame.contains("viz-calendar"))
    }

    @Test func documentAddsTheCalendarWhenUsed() {
        let page = CodexVisualize.document("<viz-calendar></viz-calendar>", title: "Day", kit: Self.kit)
        #expect(page.contains(CodexVisualize.escaped("<script>customElements.define('viz-calendar',class{})</script><viz-calendar>")))
    }

    @Test func wholeWindowUsesThePluginsShell() {
        let page = CodexVisualize.document("<p>hi</p>", title: "Hi", kit: Self.kit, full: true)
        #expect(page.contains("window.pluginShell=1;"))
        #expect(!page.contains("messageHandlers"))
        #expect(page.contains(CodexVisualize.stateMark))
    }

    @Test func fragmentsAreReadAsRenderPyReadsThem() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("codex-visualize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let good = dir.appendingPathComponent("a.html"), whole = dir.appendingPathComponent("b.html")
        try "<div>ok</div>".write(to: good, atomically: true, encoding: .utf8)
        try "<!doctype html><html><body>no</body></html>".write(to: whole, atomically: true, encoding: .utf8)
        #expect(CodexVisualize.fragment(at: good.path) == "<div>ok</div>")
        #expect(CodexVisualize.fragment(at: whole.path) == nil)
        #expect(CodexVisualize.fragment(at: dir.appendingPathComponent("none.html").path) == nil)
    }

    @Test func kitIsTheNewestInstalledVersion() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("codex-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        for version in ["1.0.9", "1.0.46", "1.0.10"] {
            let assets = home.appendingPathComponent("plugins/cache/openai-bundled/visualize/\(version)/skills/visualize/assets")
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            try "/* \(version) */".write(to: assets.appendingPathComponent("visualize.css"), atomically: true, encoding: .utf8)
        }
        #expect(CodexVisualize.skill(in: home)?.version == "1.0.46")
        #expect(CodexVisualize.homes(for: home.path + "/visualizations/2026/x.html").first?.path == home.path)
    }
}
