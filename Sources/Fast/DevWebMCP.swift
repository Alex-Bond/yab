import AppKit
import SwiftUI

struct DevWebMCPPane: View {
    struct Activity: Identifiable {
        let id = UUID()
        let name: String
        let input: String
        var status = "In progress"
        var output = ""
    }
    let browser: Browser
    @State private var tools: [[String: Any]] = []
    @State private var selected = ""
    @State private var input = "{}"
    @State private var filter = ""
    @State private var api = ""
    @State private var available = false
    @State private var activity: [Activity] = []
    @State private var running = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DevPanelBar {
                Text("Available WebMCP tools").fontWeight(.medium)
                TextField("Filter tools", text: $filter).textFieldStyle(.plain)
                Button("Refresh") { refresh() }
            }
            Divider()
            if !available {
                DevQuiet(words: error.isEmpty ? "This page does not expose a WebMCP API" : error)
            } else {
                ThreadScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(api).foregroundStyle(Palette.muted)
                        ForEach(Array(tools.enumerated()), id: \.offset) { _, tool in
                            let name = tool["name"] as? String ?? ""
                            if filter.isEmpty || name.localizedCaseInsensitiveContains(filter) {
                                Button { selected = name; input = "{}" } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(name).fontWeight(.semibold)
                                        Text(tool["description"] as? String ?? "").foregroundStyle(Palette.muted)
                                        Text(DevWorkbench.json(tool["inputSchema"])).font(DevMono.font(11)).textSelection(.enabled)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                                }.buttonStyle(.plain).background(selected == name ? Color.accentColor.opacity(0.1) : .clear)
                            }
                        }
                        if tools.isEmpty { Text("No registered tools").foregroundStyle(Palette.muted) }
                        if !selected.isEmpty {
                            Text("Arguments for \(selected)").fontWeight(.medium)
                            ThreadTextEditor(text: $input).font(DevMono.font(11.5)).frame(minHeight: 80)
                            HStack(spacing: 8) {
                                Button("Paste JSON") { if let value = NSPasteboard.general.string(forType: .string) { input = value } }
                                Button("Run tool") { run() }.disabled(running)
                                if running { Button("Cancel") { browser.workCall("tools.webmcpCancel") } }
                            }
                            Text("Running a tool can change the page or submit data.").foregroundStyle(Palette.muted)
                        }
                        if !error.isEmpty { Text(error).foregroundStyle(DevLook.red) }
                        Text("Tool activity").fontWeight(.semibold)
                        ForEach(activity) { event in
                            Text("\(event.name) · \(event.status)")
                            Text(event.input).font(DevMono.font(11)).textSelection(.enabled)
                            Text(event.output).textSelection(.enabled)
                            Divider()
                        }
                    }.font(.system(size: 12)).padding(8)
                }
            }
        }.onAppear { refresh() }
    }
    private func refresh() {
        browser.workCall("tools.webmcp") { value in
            let data = value as? [String: Any] ?? [:]
            available = data["available"] as? Bool ?? false; api = data["api"] as? String ?? ""
            tools = data["tools"] as? [[String: Any]] ?? []
        }
    }
    private func run() {
        guard let bytes = input.data(using: .utf8), (try? JSONSerialization.jsonObject(with: bytes)) is [String: Any] else { error = "Arguments must be a JSON object"; return }
        let event = Activity(name: selected, input: input); activity.insert(event, at: 0); running = true; error = ""
        browser.workCall("tools.webmcpRun", ["name": selected, "input": input]) { value in
            running = false
            if let index = activity.firstIndex(where: { $0.id == event.id }) {
                activity[index].status = value == nil ? "Error or canceled" : "Completed"
                activity[index].output = DevWorkbench.json(value)
            }
        }
    }
}
