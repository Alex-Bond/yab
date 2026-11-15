import Foundation
import Testing
@testable import Fast

/// Claude's visualize widgets in a chat (ChatItem.widget, ChatWidget): read
/// from Yab's own stream, as real calls have them
/// (trimmed from this Mac's transcripts).
@MainActor
struct ChatWidgetTests {
    static let code = """
    <h2 class="sr-only">Four ways the field could appear.</h2>
    <div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px">
    <button onclick="sendPrompt('Go with A')">A · One window ↗</button>
    </div>
    """

    @Test func theServerUnderItsIdIsTheSameTool() {
        let part: [String: Any] = ["type": "tool_use", "id": "t1", "name": "mcp__6f616b42-0ed8-571e-823f-ee4aca6b7ce9__show_widget",
                                   "input": ["title": "yab_landing_four_approaches", "loading_messages": ["Drawing four approaches"], "widget_code": "<svg></svg>"]]
        let item = ChatItem.claude(part, message: "m")
        #expect(item?.kind == .widget)
        #expect(item?.extra?["widget"] == "<svg></svg>")
        let guide = ChatItem.claude(["type": "tool_use", "id": "t0", "name": "mcp__6f616b42-0ed8-571e-823f-ee4aca6b7ce9__read_me", "input": [:]], message: "m")
        #expect(guide?.name == ChatItem.readMe)
        // Another server's show_widget-less tools are untouched.
        let other = ChatItem.claude(["type": "tool_use", "id": "t2", "name": "mcp__linear__create_issue", "input": ["title": "x"]], message: "m")
        #expect(other?.kind == .tool && other?.name == "linear/create_issue")
        #expect(ChatItem.claude(["type": "tool_use", "id": "t3", "name": "show_widget", "input": [:]], message: "m")?.kind == .tool)
    }

    @Test func loadingWordsWrittenAsAString() {
        // Two of 1,386 real calls keep the list written out.
        #expect(ChatItem.loading("['Catching a stray column', 'Waiting on the server']") == "Catching a stray column")
        #expect(ChatItem.loading(["", "Second"]) == "Second")
        #expect(ChatItem.loading("Just words") == "Just words")
        #expect(ChatItem.loading(nil) == nil)
    }

    @Test func aWidgetStillStreamingSaysItsLoadingWords() {
        // Its input as Claude Code streams it (input_json_delta), cut mid-code.
        let partial = #"{"title": "cmd_l_field", "loading_messages": ["Squeezing the \"field\"", "Snapping"#
        #expect(ChatItem.loading(partial: partial) == "Squeezing the \"field\"")
        #expect(ChatItem.loading(partial: #"{"title": "x", "loading_messages": ["Squee"#) == nil)
        // Begun with no input yet: a widget, its code not here.
        let begun = ChatItem.widget(id: "t", tool: "mcp__visualize__show_widget", input: [:])
        #expect(begun?.kind == .widget && begun?.extra?["widget"] == nil && begun?.state == .running)
    }

    @Test func titlesReadAsWords() {
        #expect(ChatItem.widgetWords("yab_landing_four_approaches") == "yab landing four approaches")
        #expect(ChatItem.widgetWords("a__b_") == "a b")
    }

    @Test func handedOverTheWidgetIsNamed() {
        let items = [ChatItem.widget(id: "widget", tool: "mcp__visualize__show_widget",
                                     input: ["title": "cmd_l_field_scale_variants", "widget_code": Self.code])! ]
        let said = Agents.conversation(items, by: "Claude")
        #expect(said.contains("Claude drew a widget: cmd l field scale variants"))
    }

    @Test func codexGeneratedPicturesAreShown() {
        let items = ChatItem.codexSteps(["type": "imageGeneration", "id": "exec-98acaa2b", "status": "completed",
                                         "revisedPrompt": "Use case: logo-brand.", "result": "iVBORw0KGgo",
                                         "savedPath": "/Users/me/.codex/generated_images/t/exec-98acaa2b.png"], done: true)
        #expect(items.first?.name == "image_gen")
        #expect(items.first?.extra?["image"] == "/Users/me/.codex/generated_images/t/exec-98acaa2b.png")
    }

    @Test func thePageHoldsTheContractAndTheCode() {
        let page = ChatWidgetPage.page(Self.code, dark: true)
        #expect(page.contains("Content-Security-Policy"))
        #expect(page.contains("default-src 'none'"))
        #expect(page.contains("https://esm.sh"))
        #expect(page.contains("data-mode=\"dark\""))
        #expect(page.contains(Self.code))
        #expect(page.contains("window.sendPrompt"))
        #expect(page.contains("tabler-icons"))
        let sheet = ChatWidgetPage.sheet()
        for name in ["--surface-1", "--text-primary", "--text-secondary", "--border", "--border-strong", "--bg-accent",
                     "--text-danger", "--font-sans", "--radius", "svg .c-purple", ".sr-only", "[data-mode=dark]"] {
            #expect(sheet.contains(name), "\(name)")
        }
        // On the whole window: no data-mode (the Mac's look), the bridge quiet.
        let full = ChatWidgetPage.page(Self.code, dark: nil, full: true)
        #expect(!full.contains("data-mode=\""))
        #expect(!full.contains("messageHandlers"))
    }
}
