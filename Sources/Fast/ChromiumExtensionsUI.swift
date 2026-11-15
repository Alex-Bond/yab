import AppKit
import SwiftUI
import WebKit

// The existing Settings rows and install question, backed by the CEF profile.
// Reading WebKit's manifest metadata here never loads a WebKit controller.
@MainActor
extension ChromiumExtensions {
    /// Source CEF asks through Chrome's own uninstall dialog delegate. Keep
    /// the existing native card as the prebuilt-CEF fallback, exactly once.
    func reviewRemoval(_ id: String, name: String, place: Question.Place) async throws -> Bool {
        let core = try await ChromiumProcess.shared.connection()
        let capabilities = try await core.request("extension.consent.capabilities")
        if capabilities["nativeConsent"] != .bool(true) {
            guard await Questions.shared.ask(Question(title: "Remove “\(name)”?",
                detail: "What it kept in Yab goes with it.", yes: "Remove", danger: true, place: place)) else { return false }
        }
        do { try await remove(id, userApproved: true); return true }
        catch {
            let words = String(describing: error).lowercased()
            if words.contains("cancelled") || words.contains("canceled") { return false }
            throw error
        }
    }
    static func of(_ browser: Browser) -> ChromiumExtensions {
        shared(profile: ChromiumPersistentProfiles.profile(for: browser), store: Spaces.store(for: browser.spaceID))
    }

    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        failure = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch {
                failure = error.localizedDescription
                _ = try? await list()
            }
        }
    }

    @available(macOS 15.4, *)
    func reviewInstall(_ id: String, browser: Browser) {
        guard !privateMode else {
            failure = "Extension management is unavailable in private profiles"
            return
        }
        perform {
            let folder = try await Self.storeFolder(id)
            let found = try await WKWebExtension(resourceBaseURL: folder)
            let wants = try await self.installLines(found, folder: folder)
            let name = found.displayName ?? id
            guard await Questions.shared.ask(Question(
                title: "Add “\(name)”?",
                detail: wants.first.map { "It will \(Extensions.lowered($0))." } ?? "It asks for no special access.",
                folded: Array(wants.dropFirst()),
                icon: found.icon(for: CGSize(width: 64, height: 64)), yes: "Add"
            )) else { return }
            try await self.load(folder: folder)
            guard try await self.list().contains(where: { $0.id == id }) else {
                throw Crx.Refused.unpack
            }
            self.pinOnArrival(id)
            browser.announce("\(name) installed", mark: "puzzlepiece.extension", feedback: .success)
        }
    }

    /// Chrome's own warnings when its management page offers them, else
    /// the words WebKit Yab asks with plus Chrome-only grants.
    @available(macOS 15.4, *)
    func installLines(_ found: WKWebExtension, folder: URL) async throws -> [String] {
        if let native = try? await permissionWarnings(folder: folder) { return native }
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        guard data.count <= 1_000_000, let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Crx.Refused.unpack
        }
        return ChromiumInstallWords.lines(manifest: manifest, yab: Extensions.describe(found, in: folder))
    }

    private static func storeFolder(_ id: String) async throws -> URL {
        let data = try await ChromiumExtensionPackages.fetch(id)
        let root = Store.file("ChromiumPackages")
        return try await Task.detached(priority: .userInitiated) {
            try ChromiumExtensionPackages.prepare(data, id: id, root: root)
        }.value
    }

    @available(macOS 15.4, *)
    func importWebKitList(_ browser: Browser) {
        perform {
            guard let previous = Extensions.unread(Extensions.signIn(of: browser.spaceID)) else {
                if !FileManager.default.fileExists(atPath: Extensions.list(of: Extensions.signIn(of: browser.spaceID)).path) { return }
                throw ImportError.unreadableList
            }
            let installed = Set(try await self.list().map(\.id))
            let missing = previous.filter { !installed.contains($0.id) || self.pendingImport.contains($0.id) }
            guard !missing.isEmpty else { return }
            guard await Questions.shared.ask(Question(
                title: "Import extensions?", detail: "Add these extensions to this space’s sign-ins.",
                lines: missing.map(\.name), yes: "Import", place: .settings
            )) else { return }
            // Fetch original, verified packages, never WebKit's rewritten files.
            let results = try await self.importList(previous) { item in
                let folder = try await Self.storeFolder(item.id)
                let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
                guard let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Crx.Refused.unpack }
                let native = ChromiumExtensionGrants.required(in: manifest)
                let additional = native.subtracting(ChromiumExtensionGrants.normalized(item.permissions))
                if !additional.isEmpty {
                    guard await Questions.shared.ask(Question(
                        title: "\(item.name) wants more", detail: "This version asks for additional access.",
                        lines: try await self.installLines(WKWebExtension(resourceBaseURL: folder), folder: folder), yes: "Add", place: .settings
                    )) else { throw ImportError.declined }
                }
                try await self.load(folder: folder)
                guard try await self.list().contains(where: { $0.id == item.id }) else {
                    throw Crx.Refused.unpack
                }
            }
            let unfinished = results.filter { $0.state == .failed || $0.state == .blocked }
            self.failure = unfinished.isEmpty ? nil : unfinished.map {
                "\($0.name): \($0.detail ?? $0.state.rawValue)"
            }.joined(separator: "\n")
        }
    }
}

/// The existing corner offer, observed without constructing a WK controller.
struct ChromiumStoreOffer: View {
    let browser: Browser
    @ObservedObject var tab: Tab
    @ObservedObject var native: ChromiumExtensions

    private var wanted: String? {
        guard !tab.shy, ChromiumStoreBridge.accepts(tab.address),
              let id = Crx.id(in: tab.address?.absoluteString ?? ""), tab.storePlaced != id,
              !native.items.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: wanted) {
                guard let id = wanted, !StoreOffer.offered.contains(id) else { return }
                let space = browser.spaceID
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, wanted == id, browser.spaceID == space,
                      StoreOffer.offered.insert(id).inserted else { return }
                browser.toaster.pop("Install in Yab", mark: "puzzlepiece.extension", undo: {
                    // A toast can outlive its page or space. Keep the offer's
                    // exact package and profile rather than a later address.
                    guard !tab.gone, !tab.shy, tab.delegate as? Browser === browser,
                          tab.engineKind == .chromium, browser.spaceID == space,
                          ChromiumStoreBridge.accepts(tab.address),
                          Crx.id(in: tab.address?.absoluteString ?? "") == id,
                          let page = tab.builtPage as? ChromiumPage, page.extensions === native else { return }
                    if #available(macOS 15.4, *) { native.reviewInstall(id, browser: browser) }
                }, act: "Add")
            }
    }
}

struct ChromiumExtensionsSettings: View {
    @ObservedObject var browser: Browser
    @ObservedObject var model: SettingsModel
    @ObservedObject var extensions: ChromiumExtensions

    var body: some View {
        Group {
            if let id = model.opened, let item = extensions.items.first(where: { $0.id == id }) {
                Section {
                    VStack(spacing: 6) {
                        mark(item, side: 64).padding(.bottom, 4)
                        Text(item.name).font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                        Text(item.about).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                        Text("Version \(item.version)").font(.callout).foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    SettingsSwitch("On", isOn: enabled(item))
                    SettingsSwitch("Pinned in the extensions list", isOn: Binding(
                        get: { extensions.pinnedIDs.contains(item.id) },
                        set: { on in
                            do { try extensions.setPinned(item.id, on) } catch { extensions.failure = error.localizedDescription }
                        }))
                    if let url = item.optionsURL {
                        SettingsRow("Options") {
                            Button("Open") { browser.tuning = false; browser.open(url, foreground: true) }.settingsButton()
                        }
                    }
                    SettingsRow("Remove", detail: "Remove the extension and its saved data from Yab.") {
                        Button("Remove…") {
                            extensions.perform {
                                guard try await extensions.reviewRemoval(id, name: item.name, place: .settings) else { return }
                                model.travel(-1)
                            }
                        }.settingsButton()
                    }
                }
            } else {
                Section {
                    ForEach(extensions.items) { item in
                        HStack(spacing: 10) {
                            HStack(spacing: 8) {
                                mark(item, side: 20)
                                Text(item.name).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { model.open(extension: item.id) }
                            Toggle("Enabled", isOn: enabled(item)).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Button { model.open(extension: item.id) } label: {
                                Symbol("chevron.right", size: 10, weight: .semibold).foregroundStyle(.tertiary)
                            }.buttonStyle(.plain).accessibilityLabel("Details for \(item.name)")
                        }
                        .opacity(item.enabled ? 1 : 0.55)
                    }
                    Button { browser.tuning = false; browser.open(Browser.webStore, foreground: true) } label: {
                        HStack(spacing: 8) { Symbol("plus", size: 11, weight: .semibold).frame(width: 20); Text("Add Extension") }
                    }.buttonStyle(.plain).foregroundStyle(Palette.muted)
                    if #available(macOS 15.4, *) {
                        Button("Import Yab Extensions…") { extensions.importWebKitList(browser) }.settingsButton()
                    }
                }
            }
            if let error = extensions.failure { Section { SettingsNote(error) } }
        }
        .disabled(extensions.busy)
        .task(id: extensions.profile) {
            do { _ = try await extensions.list() }
            catch { extensions.failure = error.localizedDescription }
        }
    }

    private func enabled(_ item: ChromiumExtensions.Item) -> Binding<Bool> {
        Binding(get: { item.enabled }, set: { on in extensions.perform { try await extensions.setEnabled(item.id, on) } })
    }

    @ViewBuilder private func mark(_ item: ChromiumExtensions.Item, side: CGFloat) -> some View {
        if let data = item.iconData, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: side, height: side)
        } else {
            Symbol("puzzlepiece.extension", size: side * 0.65).foregroundStyle(.secondary).frame(width: side, height: side)
        }
    }
}
