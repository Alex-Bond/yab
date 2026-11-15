import SwiftUI

struct DevRecorderStepEditor: View {
    @State var step: Recorder.Step
    let save: (Recorder.Step) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit step").font(.system(size: 15, weight: .semibold))
            Picker("Type", selection: $step.kind) { ForEach(Recorder.Step.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            TextField("Label", text: $step.label)
            if step.kind == .navigate { TextField("URL", text: $step.url) }
            else if step.kind == .setViewport {
                TextField("Width", value: $step.width, format: .number)
                TextField("Height", value: $step.height, format: .number)
            } else {
                TextField("Selector (CSS, aria/ or text/)", text: $step.selector)
                if [.change, .key, .waitForExpression].contains(step.kind) { TextField("Value / key / expression", text: $step.value).disabled(step.secret) }
                if step.kind == .scroll {
                    TextField("X", value: $step.x, format: .number)
                    TextField("Y", value: $step.y, format: .number)
                }
                TextField("Timeout (ms)", value: $step.timeout, format: .number)
            }
            Toggle("Breakpoint before step", isOn: $step.breakpoint)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer(minLength: 0)
                Button("Save") { step.timeout = min(60_000, max(100, step.timeout)); save(step); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.font(.system(size: 12)).padding(20).frame(width: 420)
    }
}
