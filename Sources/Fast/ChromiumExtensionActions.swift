import AppKit
import Combine
import SwiftUI
import YabCoreClient

/// The pinned buttons of a Chromium tab's extensions, drawn by Yab's own
/// column (PlatePin) from Chrome's live action state: the extension's icon,
/// its badge and title on that tab, and whether it is on there.
/// Chrome keeps that state per native tab; YabCore reads it from the
/// extension's worker (`ext.actions.state`) and says when it changed
/// (`ext.actions.changed`). Popups are hosted by the core track.
@MainActor
final class ChromiumColumn: ObservableObject {
    static let shared = ChromiumColumn()

    /// One extension's action on one page, as Chromium has it.
    struct Native: Equatable {
        var title = ""
        var badge = ""
        /// The extension shows a blocked-request count Chrome keeps from it.
        var countHidden = false
        var enabled = true
        var popup = false
        /// A dynamic icon the extension set, PNG; nil keeps its own.
        var icon: Data?
        var nativeTab: Int?
        var error: String?

        /// Nil for a row that is not this extension's or not an action.
        nonisolated static func parse(_ row: JSONValue, id: String) -> Native? {
            guard row["id"].string == id else { return nil }
            if let error = row["error"].string { return Native(error: error) }
            guard row["action"] == .bool(true) else { return nil }
            var value = Native()
            value.title = String((row["title"].string ?? "").prefix(200))
            // Chrome keeps badges short; a long one is not a badge.
            let badge = row["badge"].string ?? ""
            value.badge = badge.count <= 6 ? badge : String(badge.prefix(4))
            value.countHidden = row["countHidden"] == .bool(true)
            value.enabled = row["enabled"] != .bool(false)
            value.popup = row["popup"] == .bool(true)
            value.nativeTab = row["tabId"].number.map { Int($0) }
            if let url = row["icon"].string, url.hasPrefix("data:image/png;base64,"), url.count < 220_000 {
                value.icon = Data(base64Encoded: String(url.dropFirst("data:image/png;base64,".count)))
            }
            return value
        }
    }

    /// By page (its YabCore tab) and extension.
    @Published private(set) var states: [String: [String: Native]] = [:]
    private struct Watched { weak var tab: Tab?; let profile: String }
    private var watched: [String: Watched] = [:]
    private var reading: [String: Task<Void, Never>] = [:]
    /// The last failed read by page, for the bench (a page that cannot be read keeps the extension's own icon).
    private var failures: [String: String] = [:]
    private var again: Set<String> = []
    private var lists: [String: AnyCancellable] = [:]
    private var listedAt: [String: Date] = [:]
    private var listing: Set<String> = []
    private var images: [Data: NSImage] = [:]

    /// The tab's pinned buttons, in pin order; with `all`, then every other
    /// enabled one (Site Controls' list). Nothing for a WebKit tab.
    @available(macOS 15.4, *)
    func buttons(for tab: Tab, all: Bool = false) -> [Extensions.Button] {
        guard tab.engineKind == .chromium, !tab.shy, let page = tab.builtPage as? ChromiumPage,
              let remote = page.remoteID, let core = ChromiumProcess.shared.connectedClient else { return [] }
        let native = page.extensions
        follow(native)
        refresh(native, connectedTo: core)
        let items = Dictionary(native.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = native.pinnedIDs.compactMap { items[$0] }.filter(\.enabled)
        let rest = all ? native.items.filter { $0.enabled && !native.pinnedIDs.contains($0.id) } : []
        watch(tab, remote: remote, profile: native.profile, pinned: pinned.map(\.id))
        let here = states[remote] ?? [:]
        let pins = Set(pinned.map(\.id))
        return (pinned + rest).map { item in
            let state = here[item.id]
            let title = state?.title ?? ""
            return Extensions.Button(
                id: item.id, name: item.name,
                label: ExtensionTip.label(action: title.isEmpty ? item.name : title, name: item.name, displayName: item.name, shortName: ""),
                icon: ExtensionIconShape.rounded(image(state?.icon ?? item.iconData)),
                badge: state?.badge ?? "", enabled: state?.enabled ?? true, pinned: pins.contains(item.id))
        }
    }

    /// The cached pin identity/order, without building a page or reading the helper.
    /// A parked plate must carry different equal-height native pin sets too.
    func pinnedIDs(for tab: Tab) -> [String] {
        guard tab.engineKind == .chromium, !tab.shy, let page = tab.builtPage as? ChromiumPage else { return [] }
        let enabled = Set(page.extensions.items.filter(\.enabled).map(\.id))
        return page.extensions.pinnedIDs.filter(enabled.contains)
    }

    /// How many the column keeps room for, without reading anything.
    func pinnedCount(for tab: Tab) -> Int { pinnedIDs(for: tab).count }

    /// Open the extension's own action popup for this native page window.
    func press(_ id: String, tab: Tab) {
        guard tab.engineKind == .chromium, let page = tab.builtPage as? ChromiumPage,
              let item = page.extensions.items.first(where: { $0.id == id }) else { return }
        guard let remote = page.remoteID else { return }
        if ChromiumPopupHost.shared.toggleClosed(page: page, extensionID: id) { return }
        let hasPopup = states[remote]?[id]?.popup ?? false
        Task { @MainActor in
            // No popup on this page: its side panel, when it asked for its
            // button to open one (Chrome would show it in a window Yab hides).
            if !hasPopup, #available(macOS 15.4, *), await ChromiumSidePanel.shared.press(id, from: tab) { return }
            // Chrome's own action click on this exact page: a popup, or
            // onClicked with activeTab granted for this tab, as in Chromium.
            if await page.openExtensionAction(id) { return }
            do {
                _ = try await ChromiumDRMExtensionSession.of(tab).request("ext.actions.openPopup", ["page": remote, "extension": id])
            } catch { page.extensions.failure = "\(item.name): \(error.localizedDescription)" }
        }
    }

    private func image(_ data: Data?) -> NSImage? {
        guard let data else { return nil }
        if let known = images[data] { return known }
        guard let made = NSImage(data: data) else { return nil }
        if images.count > 256 { images.removeAll() }
        images[data] = made
        return made
    }

    private func follow(_ native: ChromiumExtensions) {
        let key = (native.privateMode ? "private:" : "regular:") + native.profile
        guard lists[key] == nil else { return }
        lists[key] = native.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
    }

    /// The column draws from the list: read it when nothing has, and again
    /// now and then, since Chrome can install or remove behind Yab's back
    /// and a first read can fail while the helper is starting.
    private func refresh(_ native: ChromiumExtensions, connectedTo core: YabCoreClient) {
        let key = (native.privateMode ? "private:" : "regular:") + native.profile
        let stale = Date().timeIntervalSince(listedAt[key] ?? .distantPast) > (native.items.isEmpty ? 1.5 : 8)
        guard stale, !listing.contains(key) else { return }
        listing.insert(key)
        listedAt[key] = Date()
        Task { @MainActor [weak self] in
            // A passive read must not wake a helper after its page crashed.
            _ = try? await native.list(connectedTo: core)
            self?.listing.remove(key)
        }
    }

    private func watch(_ tab: Tab, remote: String, profile: String, pinned: [String]) {
        let fresh = watched[remote] == nil
        watched[remote] = Watched(tab: tab, profile: profile)
        let known = Set((states[remote] ?? [:]).keys)
        guard fresh || !Set(pinned).isSubset(of: known) || watched.count > 8 else { return }
        // Drawn now; read after this pass of the column.
        DispatchQueue.main.async {
            // Only the last few pages shown are kept current.
            for (key, value) in self.watched where value.tab == nil || value.tab?.gone == true {
                self.watched[key] = nil; self.states[key] = nil
            }
            if fresh || !Set(pinned).isSubset(of: known) { self.read(remote) }
        }
    }

    /// Read again, at most one at a time per page; a change meanwhile reads once more.
    func read(_ remote: String) {
        guard let entry = watched[remote], let tab = entry.tab, !tab.gone,
              let page = tab.builtPage as? ChromiumPage, page.remoteID == remote,
              let core = ChromiumProcess.shared.connectedClient else {
            watched[remote] = nil; states[remote] = nil; return
        }
        if reading[remote] != nil { again.insert(remote); return }
        let items = Set(page.extensions.items.filter(\.enabled).map(\.id))
        let ids = page.extensions.pinnedIDs.filter(items.contains)
        guard !ids.isEmpty else { states[remote] = [:]; return }
        reading[remote] = Task { @MainActor [weak self] in
            defer {
                self?.reading[remote] = nil
                if self?.again.remove(remote) != nil { self?.read(remote) }
            }
            do {
                let result = try await ChromiumDRMExtensionSession.of(tab).request("ext.actions.state", ["page": remote, "extensions": ids], connectedTo: core)
                guard case .array(let rows) = result["actions"] else { self?.failures[remote] = "No actions array in the answer"; return }
                var next: [String: Native] = [:]
                for id in ids { if let row = rows.first(where: { $0["id"].string == id }), let state = Native.parse(row, id: id) { next[id] = state } }
                self?.failures[remote] = nil
                if self?.states[remote] != next { self?.states[remote] = next }
            } catch {
                // A page that cannot be read keeps the extension's own icon.
                self?.failures[remote] = String(describing: error)
                if self?.states[remote] == nil { self?.states[remote] = [:] }
            }
        }
    }

    /// `ext.actions.changed` from a profile's control tab.
    static func receive(_ event: YabCoreEvent) -> Bool {
        guard event.name == "ext.actions.changed" else { return false }
        guard let profile = event.params["profile"]?.string, let id = event.params["extension"]?.string,
              ChromiumExtensions.validID(id) else { return true }
        let column = shared
        // A worker that just started may still be running the listener that
        // sets its badge; read again once it has had a moment.
        let restarted = event.params["reason"]?.string == "worker"
        for (remote, entry) in column.watched where entry.profile == profile {
            guard let page = entry.tab?.builtPage as? ChromiumPage, page.extensions.pinnedIDs.contains(id) else { continue }
            column.read(remote)
            if restarted { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { column.read(remote) } }
        }
        return true
    }
}

@MainActor
extension ChromiumExtensions {
    /// Pin or unpin in the column; kept beside the import's pin order.
    func setPinned(_ id: String, _ pinned: Bool) throws {
        guard Self.validID(id) else { throw YabCoreError.remote("A Chrome extension ID is required") }
        var state = try migration()
        state.pins.removeAll { $0 == id }
        if pinned { state.pins.append(id) }
        try saveMigration(state)
    }

    /// A password manager comes in pinned, the first time, as on WebKit.
    func pinOnArrival(_ id: String) {
        guard var state = try? migration(), Extensions.passwordManagers.contains(id),
              !(state.arrived ?? []).contains(id) else { return }
        state.arrived = (state.arrived ?? []).union([id])
        if !state.pins.contains(id) { state.pins.insert(id, at: 0) }
        try? saveMigration(state)
    }
}

/// What a right-click on a Chromium tab's pinned extension offers, the
/// WebKit button's lines (ExtensionActions) over the native profile.
struct ChromiumPinActions: View {
    let id: String
    let name: String
    let tab: Tab

    private var native: ChromiumExtensions? { (tab.builtPage as? ChromiumPage)?.extensions }

    var body: some View {
        if let native {
            let pinned = native.pinnedIDs.contains(id)
            SwiftUI.Button(pinned ? "Unpin" : "Pin", mark: "pin") { try? native.setPinned(id, !pinned) }
            if let url = native.items.first(where: { $0.id == id })?.optionsURL {
                SwiftUI.Button("Options…", mark: "gearshape") {
                    (tab.delegate as? Browser)?.open(url, foreground: true)
                }
            }
            Divider()
            SwiftUI.Button("Remove from Yab…", mark: "trash") {
                native.perform {
                    guard try await native.reviewRemoval(id, name: name, place: .plain) else { return }
                    try? native.setPinned(id, false)
                }
            }
        }
    }
}

extension ChromiumColumn {
    /// The bench's view of a Chromium tab's column: the buttons as drawn,
    /// Chrome's raw action state, and the pin order. `pin` pins or unpins
    /// first; `read` asks for a fresh read.
    @available(macOS 15.4, *)
    static func benchState(tab: Tab, page: ChromiumPage, pin: String?, pinned: Bool, read: Bool) -> [String: Any] {
        var failure: String?
        if let pin {
            do { try page.extensions.setPinned(pin, pinned) } catch { failure = error.localizedDescription }
        }
        let column = shared
        let buttons = column.buttons(for: tab)
        if read, let remote = page.remoteID { column.read(remote) }
        let states = page.remoteID.flatMap { column.states[$0] } ?? [:]
        var out: [String: Any] = [
            "pins": page.extensions.pinnedIDs,
            "items": page.extensions.items.map { ["id": $0.id, "name": $0.name, "state": $0.state] },
            "buttons": buttons.map { button -> [String: Any] in
                ["id": button.id, "label": button.label, "badge": button.badge, "enabled": button.enabled,
                 "icon": button.icon.map { [$0.size.width, $0.size.height] } ?? []]
            },
            "native": states.mapValues { state -> [String: Any] in
                ["title": state.title, "badge": state.badge, "countHidden": state.countHidden, "enabled": state.enabled,
                 "popup": state.popup, "dynamicIcon": state.icon?.count ?? 0, "nativeTab": state.nativeTab ?? -1,
                 "error": state.error ?? ""]
            },
            "reading": page.remoteID.map { column.reading[$0] != nil } ?? false,
            "readFailure": page.remoteID.flatMap { column.failures[$0] } ?? "",
            "watching": page.remoteID.map { column.watched[$0] != nil } ?? false,
            "enabledItems": page.extensions.items.filter(\.enabled).map(\.id),
            "failure": page.extensions.failure ?? "",
        ]
        // What the store install shows: the corner offer and Yab's question.
        if let up = Questions.shared.current {
            out["question"] = ["title": up.title, "detail": up.detail, "folded": up.folded, "lines": up.lines, "yes": up.yes] as [String: Any]
        }
        if let toaster = (tab.delegate as? Browser)?.toaster, toaster.shown {
            out["toast"] = ["words": toaster.words, "act": toaster.act ?? ""]
        }
        if let failure { out["error"] = failure }
        if let failed = page.extensions.failure { out["extensionsFailure"] = failed }
        return out
    }
}
