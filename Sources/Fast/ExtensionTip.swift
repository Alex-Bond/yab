import AppKit

/// What an extension's button says in its tip, its short name and its
/// key, worked out the same way whether the extension is loaded or still
/// asleep (Extensions.buttons): before, a button asleep or waiting its
/// turn said its whole store name and no key at all.
enum ExtensionTip {
    /// The commands that press the button itself.
    static let pressCommands = ["_execute_action", "_execute_browser_action"]

    /// One of its commands with a key, as the manifest suggests it or as
    /// someone set it in Settings.
    struct Key: Equatable {
        let command: String
        let hotkey: Hotkey
    }

    /// What a manifest says about the button, read without loading it.
    struct Facts: Equatable {
        /// The manifest's short_name, translated; "" for none.
        var shortName = ""
        /// The action's default_title, translated; "" for none.
        var title = ""
        var keys: [Key] = []
        /// Every command it has, the button's own first: its id and the
        /// manifest's words for it ("" for the button's).
        var commands: [Command] = []
    }

    struct Command: Equatable {
        let id: String
        let title: String
    }

    /// The tip's words. The extension's own title for its button when it
    /// gives one; when that is only its name, the manifest's short name,
    /// else the store name up to where it turns into a sentence:
    /// "NordPass® Password Manager & Digital Vault" is NordPass,
    /// "BrowserStack Bug Capture: Report & resolve bugs faster" is
    /// BrowserStack Bug Capture.
    static func label(action: String, name: String, displayName: String?, shortName: String) -> String {
        let named = action.isEmpty || action == name || action == displayName
        guard named else { return action }
        // WebKit's displayShortName is the whole name when the manifest
        // gives no short_name, so the short name is cut too.
        return short(shortName.isEmpty ? name : shortName)
    }

    static func short(_ name: String) -> String {
        var cut = name
        for mark in ["®", "™", ": ", " | ", " - ", " – ", " — "] {
            guard let range = cut.range(of: mark) else { continue }
            let head = cut[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if head.count >= 2 { cut = head }
        }
        return cut
    }

    /// The key the tip shows: the button's own, the one that presses it.
    /// A key of another command (BrowserStack's ⌥⇧S takes a screenshot) is
    /// not the button's, and Chrome's and Arc's tips show none: it stays
    /// in Settings › Extensions, with what it does.
    static func buttonKey(_ keys: [Key]) -> Key? {
        keys.first { pressCommands.contains($0.command) }
    }

    // MARK: - read from the manifest

    /// The manifest's facts, with the keys someone set in Settings
    /// (`extensions.keys.<id>`) over the ones it suggests.
    static func facts(_ manifest: [String: Any], folder: URL, saved: [String: Any]) -> Facts {
        let locale = manifest["default_locale"] as? String
        func text(_ value: Any?) -> String {
            guard let value = value as? String, !value.isEmpty else { return "" }
            let out = Chromium.localized(value, in: folder, locale: locale)
            return out.hasPrefix("__MSG_") ? "" : out
        }
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        return Facts(shortName: text(manifest["short_name"]), title: text(action?["default_title"]),
                     keys: keys(manifest, saved: saved), commands: commands(manifest, text: text))
    }

    /// Its commands as WebKit lists them: the button's own whenever it has
    /// a button, one name for it whichever the manifest uses.
    static func commands(_ manifest: [String: Any], text: (Any?) -> String = { $0 as? String ?? "" }) -> [Command] {
        let declared = manifest["commands"] as? [String: Any] ?? [:]
        let button = manifest["action"] != nil || manifest["browser_action"] != nil
            || pressCommands.contains { declared[$0] != nil }
        let others = declared.keys.filter { !pressCommands.contains($0) }.sorted().map { id in
            Command(id: id, title: text((declared[id] as? [String: Any])?["description"]))
        }
        let press = manifest["manifest_version"] as? Int == 2 && declared["_execute_action"] == nil ? "_execute_browser_action" : "_execute_action"
        return (button ? [Command(id: press, title: "")] : []) + others
    }

    static func keys(_ manifest: [String: Any], saved: [String: Any]) -> [Key] {
        var commands = manifest["commands"] as? [String: Any] ?? [:]
        // As ExtensionShims.mendActionCommands leaves them for WebKit,
        // which lists the button's command whether the manifest names it
        // or not, so a key can be set for it.
        if commands["_execute_action"] != nil { commands["_execute_browser_action"] = nil }
        var out: [Key] = []
        for id in Set(commands.keys).union(saved.keys).sorted() where commands[id] != nil || pressCommands.contains(id) {
            if let entry = saved[id] as? [String: Any], let key = entry["key"] as? String {
                guard !key.isEmpty else { continue }
                out.append(Key(command: id, hotkey: Hotkey(key, NSEvent.ModifierFlags(rawValue: UInt(entry["flags"] as? Int ?? 0)))))
                continue
            }
            let suggested = (commands[id] as? [String: Any])?["suggested_key"] as? [String: Any] ?? [:]
            guard let combo = (suggested["mac"] ?? suggested["default"]) as? String, let hotkey = hotkey(combo) else { continue }
            out.append(Key(command: id, hotkey: hotkey))
        }
        // The button's own first.
        return out.filter { pressCommands.contains($0.command) } + out.filter { !pressCommands.contains($0.command) }
    }

    /// Chrome's "Alt+Shift+S", "Command+Shift+Period": on a Mac, Ctrl in
    /// a default is ⌘ and MacCtrl is ⌃.
    static func hotkey(_ combo: String) -> Hotkey? {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in combo.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part.lowercased() {
            case "ctrl", "command": flags.insert(.command)
            case "macctrl": flags.insert(.control)
            case "alt": flags.insert(.option)
            case "shift": flags.insert(.shift)
            case "comma": key = ","
            case "period": key = "."
            case "space": key = " "
            case "home": key = "home"
            case "end": key = "end"
            case "pageup": key = "pageup"
            case "pagedown": key = "pagedown"
            case "up": key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case "down": key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case "left": key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case "right": key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case let other where other.count == 1: key = other
            case let other where other.hasPrefix("f") && Int(other.dropFirst()) != nil: key = other
            default: return nil
            }
        }
        guard let key, !flags.isEmpty else { return nil }
        return Hotkey(key, flags)
    }
}
