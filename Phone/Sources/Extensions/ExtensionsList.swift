import SwiftUI

/// Every extension, as Settings lists things: its mark, its name and
/// version, a switch; held, Settings or Remove. Under them, where more come
/// from: Yab on the Mac.
struct ExtensionsList: View {
    @Environment(ExtensionHost.self) private var host
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !host.installed.isEmpty {
                    Section {
                        ForEach(host.installed) { item in
                            row(item)
                        }
                    } footer: {
                        Text("Extensions run on every page you open in Yab, as on your Mac.")
                    }
                }
                if ProcessInfo.processInfo.environment["YAB_TEST"] == "1", !host.events.isEmpty {
                    Section("Events") {
                        Text(host.events.joined(separator: "\n")).font(.caption2.monospaced())
                            .accessibilityIdentifier("extensions.events")
                    }
                }
                // No way to the store here (register 617): adding an
                // extension is on the Mac.
                Section {
                } footer: {
                    Text("Add extensions in Yab on your Mac.")
                }
            }
            .navigationTitle("Extensions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("extensions.done")
                }
            }
        }
    }

    private func row(_ item: ExtensionHost.Installed) -> some View {
        let button = host.buttons().first { $0.id == item.id }
        return HStack(spacing: 12) {
            Group {
                if let icon = button?.icon { Image(uiImage: icon).resizable() }
                else { Image(systemName: "puzzlepiece.extension").resizable().scaledToFit().foregroundStyle(.secondary) }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(1)
                Text(item.version).font(.footnote).foregroundStyle(.secondary)
                if let verdict = host.compatibility(item.id), verdict.kind != .works {
                    Text(verdict.reason).font(.caption).foregroundStyle(.secondary).lineLimit(4)
                        .accessibilityIdentifier("extensions.limited")
                }
                ForEach(host.problems(item.id), id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.red).lineLimit(4)
                        .accessibilityIdentifier("extensions.problem")
                }
            }
            Spacer(minLength: 8)
            Toggle(item.name, isOn: Binding(get: { item.enabled }, set: { host.setEnabled(item.id, $0) }))
                .labelsHidden()
                .accessibilityIdentifier("extensions.toggle.\(item.id)")
        }
        .accessibilityIdentifier("extensions.row.\(item.id)")
        .contextMenu {
            if host.hasOptions(item.id) {
                Button { dismiss(); host.openOptions(item.id) } label: { Label { Text("Settings") } icon: { menuGlyph(.gearshape) } }
            }
            Button(role: .destructive) { host.remove(item.id) } label: { Label { Text("Remove") } icon: { menuGlyph(.trash) } }
        }
        .background(SpaceSwipeRowRegion())
        .swipeActions {
            Button(role: .destructive) { host.remove(item.id) } label: { Label { Text("Remove") } icon: { menuGlyph(.trash) } }
        }
    }
}

/// A context menu's mark in the Mac's drawing for the same action.
private func menuGlyph(_ glyph: MacGlyph) -> Image {
    UIImage.menuGlyph(glyph).map { Image(uiImage: $0) } ?? Image(systemName: "circle")
}

extension AppModel {
    /// The Chrome Web Store, in a tab of the space in front.
    func openStore() {
        guard let url = URL(string: "https://chromewebstore.google.com/category/extensions") else { return }
        let tab = PageFixtures.tab(for: url, isPrivate: browser.space.isPrivate, in: world, fixturesEnabled: fixturesEnabled)
        browser.open(tab, deduplicate: false)
        profile?.capture(browser)
    }
}
