import AppKit
import SwiftUI

// Bringing over the extensions another Chromium browser has.
//
// Each profile lists its extensions in its preferences, "Secure
// Preferences" nowadays, plain "Preferences" in older ones, under
// extensions.settings: where each came from, whether it is on, and the
// folder it runs from. The browser's own pieces (its PDF viewer, its web
// store, Arc's and Dia's internals) are listed there too and are left out.
//
// One from the Chrome Web Store is fetched again from the store and checked
// the way any install is, rather than copied: the copy on disk is whatever
// anything with access to the folder left there, and the store's is signed.
// Only when the store no longer has it is the other browser's copy taken,
// the way a folder chosen by hand is. An unpacked one is its developer's
// folder, and is loaded from there, Reload and all.
//
// The extension comes over; what it kept doesn't. Its storage, its
// sign-ins, its IndexedDB are in Chromium's own files and under Chromium's
// own origins, so you sign in to it again, when you open it: it hears it
// was updated, not installed, so no welcome or sign-in page opens by
// itself (Extensions.broughtIn).

extension Chromium {
    struct Extension: Identifiable, Hashable {
        let id: String
        let name: String
        let fromStore: Bool
        /// On in at least one of the browser's profiles.
        let enabled: Bool
        /// The copy the other browser runs.
        let folder: URL
        let iconFile: URL?
        /// An ad blocker's sites with blocking off and hiding rules, from
        /// its storage in that profile (BlockerKept), nil for none.
        var kept: BlockerKept? = nil
        /// The keys its commands have there, by command, as the profile's
        /// Preferences keep them for a Mac (extensions.commands, Arc's and
        /// Dia's too): "Command+Shift+W", Ctrl being ⌃ there.
        var keys: [String: String] = [:]
        /// The profiles it is on in, by folder ("Default", "Profile 1"), or
        /// those it is in at all when it is on in none: each profile came
        /// in as a space, and its extensions go to that space's sign-in.
        var profiles: [String] = []

        var isBlocker: Bool { kept != nil || Blockers.known[id] != nil }
        /// uBlock Origin itself: Manifest V2, it can't block on WebKit, so
        /// what it kept comes over and it doesn't.
        var keptOnly: Bool { id == Blockers.classic }
    }

    /// What the given browser has, every profile together, the ones that are
    /// on first.
    static func extensions(in source: Source) -> [Extension] {
        var found: [String: Extension] = [:]
        var onIn: [String: [String]] = [:], inAt: [String: [String]] = [:]
        for profile in source.profiles {
            var settings: [String: [String: Any]] = [:]
            var keys: [String: [String: String]] = [:]
            for name in ["Preferences", "Secure Preferences"] {
                guard let data = try? Data(contentsOf: profile.appendingPathComponent(name)),
                      let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = top["extensions"] as? [String: Any]
                else { continue }
                for (id, given) in commandKeys(extensions["commands"]) { keys[id, default: [:]].merge(given) { _, newer in newer } }
                guard let all = extensions["settings"] as? [String: Any] else { continue }
                for (id, value) in all {
                    guard let entry = value as? [String: Any] else { continue }
                    settings[id, default: [:]].merge(entry) { _, newer in newer }
                }
            }
            for (id, entry) in settings {
                guard var item = extensionEntry(id, entry, in: profile) else { continue }
                item.keys = keys[id] ?? [:]
                inAt[id, default: []].append(profile.lastPathComponent)
                if item.enabled { onIn[id, default: []].append(profile.lastPathComponent) }
                if let seen = found[id] {
                    if item.enabled, !seen.enabled || (seen.kept == nil && item.kept != nil) { found[id] = item }
                } else {
                    found[id] = item
                }
            }
        }
        for id in found.keys { found[id]?.profiles = onIn[id] ?? inAt[id] ?? [] }
        return found.values.sorted { a, b in
            a.enabled != b.enabled ? a.enabled : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// extensions.commands: every key given to an extension's command, by
    /// the key, for each kind of computer, "mac:Command+Shift+W", with the
    /// extension and its command. The Mac's, by extension and command.
    static func commandKeys(_ value: Any?) -> [String: [String: String]] {
        var out: [String: [String: String]] = [:]
        for (key, value) in value as? [String: Any] ?? [:] {
            guard key.hasPrefix("mac:"), let entry = value as? [String: Any],
                  let id = entry["extension"] as? String, let command = entry["command_name"] as? String else { continue }
            // A media key's carries the extension's id after it.
            let combo = key.dropFirst(4).split(separator: ":").first.map(String.init) ?? ""
            guard !combo.isEmpty else { continue }
            out[id, default: [:]][command] = combo
        }
        return out
    }

    /// A key as Chromium keeps it for a Mac: Command is ⌘ and Ctrl is ⌃,
    /// unlike a manifest's suggestion, whose Ctrl is ⌘ (ExtensionTip.hotkey).
    static func storedHotkey(_ combo: String) -> Hotkey? {
        let parts = combo.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        return ExtensionTip.hotkey(parts.map { $0.lowercased() == "ctrl" ? "MacCtrl" : $0 }.joined(separator: "+"))
    }

    private static func extensionEntry(_ id: String, _ entry: [String: Any], in profile: URL) -> Extension? {
        let location = entry["location"] as? Int
        let fromStore = entry["from_webstore"] as? Bool == true
        // 4 is unpacked; the store's own come as 1, or 6 when another app
        // asked for them. 5 and 10 are the browser's own pieces.
        let unpacked = location == 4
        guard unpacked || (fromStore && location != 5 && location != 10),
              entry["was_installed_by_default"] as? Bool != true,
              entry["was_installed_by_oem"] as? Bool != true,
              let path = entry["path"] as? String, !path.isEmpty
        else { return nil }
        let folder = path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : profile.appendingPathComponent("Extensions", isDirectory: true).appendingPathComponent(path, isDirectory: true)
        let manifestFile = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestFile),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // Themes and Chrome apps aren't extensions WebKit can run.
              manifest["theme"] == nil, manifest["app"] == nil
        else { return nil }
        // Chrome says why it is off in disable_reasons; older ones kept a
        // state of 0 instead.
        let reasons = entry["disable_reasons"]
        let disabled = (reasons as? [Any]).map { !$0.isEmpty } ?? ((reasons as? Int ?? 0) != 0)
        let enabled = !disabled && (entry["state"] as? Int ?? 1) != 0
        let locale = manifest["default_locale"] as? String
        let name = localized(manifest["name"] as? String ?? id, in: folder, locale: locale)
        let blocker = Blockers.known[id] != nil || Blockers.isBlocker(manifest: manifest, folder: folder)
        return Extension(id: id, name: name, fromStore: fromStore && !unpacked, enabled: enabled, folder: folder, iconFile: icon(manifest, in: folder),
                         kept: blocker ? BlockerKept.read(id, in: profile) : nil)
    }

    /// "__MSG_appName__" is a key into the extension's own translations: the
    /// ones for the languages this Mac is set to, then its default.
    static func localized(_ text: String, in folder: URL, locale: String?) -> String {
        guard text.hasPrefix("__MSG_"), text.hasSuffix("__"), text.count > 8 else { return text }
        let key = String(text.dropFirst(6).dropLast(2)).lowercased()
        let wanted = Locale.preferredLanguages.flatMap { code in
            [code.replacingOccurrences(of: "-", with: "_"), String(code.prefix(2))]
        } + [locale ?? "en"]
        for code in wanted {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("_locales/\(code)/messages.json")),
                  let messages = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            for (name, value) in messages where name.lowercased() == key {
                if let message = (value as? [String: Any])?["message"] as? String, !message.isEmpty { return message }
            }
        }
        return text
    }

    /// The largest of its icons, 128 points at most.
    static func icon(_ manifest: [String: Any], in folder: URL) -> URL? {
        guard let icons = manifest["icons"] as? [String: String] else { return nil }
        let sized = icons.compactMap { size, path in Int(size).map { ($0, path) } }.sorted { $0.0 < $1.0 }
        guard let pick = sized.last(where: { $0.0 <= 128 }) ?? sized.first else { return nil }
        return folder.appendingPathComponent(pick.1)
    }
}

@available(macOS 15.4, *)
extension Extensions {
    /// Asks once for the lot, then installs them one by one, and says once
    /// how it went. Without `asking` when the asking was done already, a
    /// switch left on in the welcome.
    func bringIn(_ picked: [Chromium.Extension], from browserName: String, asking: Bool = true) {
        guard !picked.isEmpty, busy == nil else { return }
        Task { await bringingIn(picked, from: browserName, asking: asking) }
    }

    /// `bringIn`'s work, awaited: what came, and the names of those that
    /// couldn't. `say`: the corner says how it went. Unasked, it waits for
    /// an install under way here to end rather than skipping the lot.
    @discardableResult
    func bringingIn(_ picked: [Chromium.Extension], from browserName: String, asking: Bool = true, say: Bool = true) async -> (added: Int, failed: [String]) {
        guard !picked.isEmpty else { return (0, []) }
        if asking {
            guard busy == nil else { return (0, []) }
        } else {
            while busy != nil { try? await Task.sleep(for: .milliseconds(200)) }
        }
        let names = picked.map(\.name)
        let one = picked.count == 1
        if asking {
            let accepted = await ask(Question(
                title: one ? "Add “\(picked[0].name)” from \(browserName)?" : "Add \(picked.count) extensions from \(browserName)?",
                detail: "Each can do here what it could there. What they kept, sign-ins and settings, stays in \(browserName).",
                lines: one ? [] : Array(names.prefix(8)) + (names.count > 8 ? ["and \(names.count - 8) more"] : []),
                lineGlyph: "puzzlepiece.extension",
                icon: one ? picked[0].iconFile.flatMap(NSImage.init(contentsOf:)) : nil,
                yes: "Add"
            ))
            guard accepted else { return (0, []) }
        }
        var failed: [String] = []
        let before = Set(installed.map(\.id))
        for item in picked {
            busy = item.id
            if await !bringOne(item, from: browserName) { failed.append(item.name) }
        }
        busy = nil
        arrivedQuietly(installed.map(\.id).filter { !before.contains($0) })
        let added = picked.count - failed.count
        if say { Extensions.sayBrought(added: added, failed: failed.count, one: one ? picked[0].name : nil, in: browser) }
        return (added, failed)
    }

    /// How a bringing in went, in the corner.
    static func sayBrought(added: Int, failed: Int, one: String?, in browser: Browser?) {
        if failed == 0 {
            browser?.announce(one.map { "\($0) installed" } ?? "\(added) extensions installed", mark: "puzzlepiece.extension", feedback: .success)
        } else if added == 0 {
            browser?.announce(one.map { "Couldn't install \($0)" } ?? "None could be installed", mark: "exclamationmark.triangle")
        } else {
            browser?.announce("\(added) installed, \(failed) failed", mark: "puzzlepiece.extension", feedback: .success)
        }
    }

    /// A browser's extensions brought in as its profiles came in: each
    /// into the sign-in of the space its profile is (`signedInAs`), as
    /// Arc and Chrome keep extensions per profile; the first profile's,
    /// and a profile's with no space here, into the shared sign-in. Every
    /// one once went to the shared sign-in, and a space brought in from
    /// Arc's second profile had none of its extensions (#358). One sign-in
    /// after another: two installing the same extension at once would
    /// share its folder as it is unpacked.
    static func bringIn(byProfile picked: [Chromium.Extension], from source: Chromium.Source, spaces: [Space]) {
        let groups = profileTargets(picked, from: source.name, spaces: spaces).compactMap { group -> (Extensions, [Chromium.Extension])? in
            let target = instance(group.signIn)
            let here = Set(target.installed.map(\.id)), folders = Set(target.installed.compactMap(\.source))
            let items = group.items.filter { !here.contains($0.id) && !folders.contains($0.folder.path) }
            return items.isEmpty ? nil : (target, items)
        }
        guard !groups.isEmpty else { return }
        Task {
            var added = 0, failed = 0
            for (target, items) in groups {
                let one = await target.bringingIn(items, from: source.name, asking: false, say: false)
                added += one.added
                failed += one.failed.count
            }
            let all = groups.flatMap(\.1)
            sayBrought(added: added, failed: failed, one: all.count == 1 ? all[0].name : nil,
                       in: BrowserWindows.shared.activeBrowser ?? shared.browser)
        }
    }

    /// Which sign-in each extension goes to, by the profiles it is on in:
    /// the shared one first, then the spaces' own, in the spaces' order.
    static func profileTargets(_ picked: [Chromium.Extension], from browserName: String, spaces: [Space]) -> [(signIn: UUID?, items: [Chromium.Extension])] {
        var order: [UUID?] = []
        var groups: [UUID?: [Chromium.Extension]] = [:]
        for item in picked {
            var targets: [UUID?] = []
            for profile in item.profiles {
                let own = spaces.filter { $0.ownSignIns && $0.signedInAs == "\(browserName):\(profile)" }.map { signIn(of: $0.id) }
                targets += own.isEmpty ? [nil] : own
            }
            for target in targets.isEmpty ? [nil] : targets where !(groups[target] ?? []).contains(where: { $0.id == item.id }) {
                if groups[target] == nil { order.append(target) }
                groups[target, default: []].append(item)
            }
        }
        return (order.filter { $0 == nil } + order.filter { $0 != nil }).map { ($0, groups[$0] ?? []) }
    }

    /// For Settings, which says itself how it is going: one by one, with
    /// each started one's id handed to `step` as it lands. The ids that got
    /// in, in order.
    func bring(_ picked: [Chromium.Extension], from browserName: String = "Chrome", step: (Int) -> Void) async -> [String] {
        var added: [String] = []
        for (index, item) in picked.enumerated() {
            step(index)
            busy = item.id
            let before = Set(installed.map(\.id))
            // Installed counts, started or not: its page says if it couldn't start.
            _ = await bringOne(item, from: browserName)
            if let new = installed.map(\.id).first(where: { !before.contains($0) }) { added.append(new) }
        }
        busy = nil
        return added
    }

    /// A blocker's sites and hiding rules, into Yab's own places, so they
    /// work whichever blocks: sites off in `shield.paused`, hiding rules as
    /// Hide Elements on their site.
    func bringKept(_ item: Chromium.Extension, from browserName: String) {
        guard let kept = item.kept, !kept.isEmpty else { return }
        Blockers.broughtWith[item.id] = (kept.sites.count, kept.hiding.count)
        for host in kept.sites where !Shield.shared.isPaused(on: host) { Shield.shared.pause(host, true) }
        if !kept.sites.isEmpty {
            Store.settings.set("\(item.name) in \(browserName)", forKey: "shield.pausedFrom")
            Shield.shared.apply()
        }
        if let curtain = browser?.curtain {
            for hide in kept.hiding {
                curtain.hide(hide.selector, label: "From \(item.name)", note: "Brought from \(browserName)", on: hide.host)
            }
        }
    }

    /// The keys someone gave its commands in the browser it came from
    /// (chrome://extensions/shortcuts, Arc's and Dia's the same), onto its
    /// commands here. A key it only suggests is already its key here. One
    /// given there wins over a key Yab has by default, as an extension's
    /// assigned key wins in Chrome and Arc: Close Window lets ⇧⌘W go for
    /// the Great Suspender (feedback #163). Never over a key someone chose
    /// here: one they set for this command, one they gave Yab's own
    /// command, or another extension's, a snippet's, a quick action's.
    func bringKeys(_ item: Chromium.Extension, as id: String) {
        guard !item.keys.isEmpty,
              let data = try? Data(contentsOf: Extensions.folder(for: id).appendingPathComponent("manifest.json")),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let commands = ExtensionTip.commands(manifest).map(\.id)
        let suggested = Dictionary(ExtensionTip.keys(manifest, saved: [:]).map { ($0.command, $0.hotkey) }, uniquingKeysWith: { first, _ in first })
        let saved = Store.settings.dictionary(forKey: "extensions.keys.\(id)") ?? [:]
        let keymap = Keymap.shared
        for (given, combo) in item.keys.sorted(by: { $0.key < $1.key }) {
            // The button's command, whichever name the other browser keeps it by.
            let command = ExtensionTip.pressCommands.contains(given)
                ? commands.first { ExtensionTip.pressCommands.contains($0) } ?? given : given
            guard commands.contains(command), let hotkey = Chromium.storedHotkey(combo),
                  saved[command] == nil, suggested[command] != hotkey else { continue }
            let own = contexts[id]?.commands.first { $0.id == command }
            switch keymap.clash(hotkey, for: nil, command: own, takeSeveral: false) {
            case nil:
                setKey(hotkey, extension: id, command: command)
            case .taken(_, let free):
                guard let action = keymap.action(for: hotkey), keymap.isDefault(action),
                      keymap.systemBrowserAction(for: hotkey) == nil else {
                    NSLog("Extensions: %@ kept from %@'s %@, someone chose it here", hotkey.text, id, command)
                    continue
                }
                free()
                setKey(hotkey, extension: id, command: command)
            case .refused(let why):
                NSLog("Extensions: %@ not brought for %@'s %@: %@", hotkey.text, id, command, why)
            }
        }
    }

    private func bringOne(_ item: Chromium.Extension, from browserName: String) async -> Bool {
        guard !ApplePasswordExtensionRoute.intercept(item.id, browser: browser) else { return false }
        bringKept(item, from: browserName)
        // uBlock Origin can't run here: what it kept is all that comes.
        if item.keptOnly { return true }
        let files = FileManager.default
        // Installed there already: nothing it opens on "install" opens here.
        broughtIn.insert(item.id)
        if item.fromStore {
            let staged = Extensions.folder.appendingPathComponent(".staging-\(item.id)", isDirectory: true)
            do {
                let zip = try Crx.verifiedZip(try await Crx.fetch(item.id), id: item.id)
                try Crx.unpack(zip, into: staged)
                try ExtensionShims.prepare(staged)
                let added = try await admit(staged, as: item.id, fromStore: true, finalFolder: Extensions.folder(for: item.id), confirm: false, quiet: true)
                if added { bringKeys(item, as: item.id) }
                return added
            } catch {
                try? files.removeItem(at: staged)
                NSLog("Extensions: %@ from the store failed (%@); taking the other browser's copy", item.id, error.localizedDescription)
            }
        }
        // A store one the store no longer has keeps its id, so what it
        // stores and the sites that look for it find it where they did.
        let id = item.fromStore ? item.id : "local-" + String(UUID().uuidString.prefix(8)).lowercased()
        broughtIn.insert(id)
        let staged = Extensions.folder.appendingPathComponent(".staging-\(id)", isDirectory: true)
        do {
            try files.createDirectory(at: Extensions.folder, withIntermediateDirectories: true)
            try? files.removeItem(at: staged)
            try files.copyItem(at: item.folder, to: staged)
            try ExtensionShims.prepare(staged)
            let added = try await admit(staged, as: id, fromStore: false, finalFolder: Extensions.folder(for: id), confirm: false, source: item.fromStore ? nil : item.folder, quiet: true)
            if added { bringKeys(item, as: id) }
            return added
        } catch {
            try? files.removeItem(at: staged)
            NSLog("Extensions: couldn't bring %@ in: %@", item.id, error.localizedDescription)
            return false
        }
    }
}
