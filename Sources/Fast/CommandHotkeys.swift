import AppKit

extension Command {
    /// Existing menu, place and legacy actions keep their single settings row.
    var shortcutAction: Shortcut.Action? {
        MenuCommands.entries[self]?.shortcut ?? MenuCommands.legacyKeys[self]
            ?? FieldPlace.of(self)?.shortcut ?? (self == .blankWindow ? .blankWindow : nil)
            ?? (self == .pasteAndMatchStyle ? .pasteAndMatchStyle : nil)
    }

    /// Opposite states use one binding, just as existing menu toggles do.
    var shortcutCommand: Command {
        switch self {
        case .customizationOff: .customizationOn
        case .showSiteButtons: .hideSiteButtons
        case .allowSiteSleep: .keepSiteAwake
        case .unmuteSite: .muteSite
        case .hideChat: .showChat
        case .showSiteURL: .showFullURL
        case .exitFullScreen: .fullScreen
        case .darkTheme: .lightTheme
        case .unpinChatProject: .pinChatProject
        case .unarchiveChatProject: .archiveChatProject
        case .disableProjectMemory: .enableProjectMemory
        default: self
        }
    }

    var shortcutID: String { "command." + shortcutCommand.rawValue }
    /// The one key for both states says what it does, not which way it goes.
    var shortcutTitle: String { shortcutCommand == .lightTheme ? "Toggle Light and Dark Mode" : title }
    var defaultHotkey: Hotkey? { shortcutCommand == .tidyTabs ? Hotkey("t", [.control, .command]) : nil }
}

/// Derived from the command field's catalog, never a second list of actions.
enum CommandHotkeys {
    /// The experiment's half of the menu catalog gets no rows.
    static let commands = Command.allCases.filter {
        $0.shortcutAction == nil && $0.shortcutCommand == $0
            && (MenuCommands.entries[$0] == nil || MenuCommands.everyone.contains($0))
    }

    static func variants(of command: Command) -> [Command] {
        Command.allCases.filter { $0.shortcutAction == nil && $0.shortcutCommand == command.shortcutCommand }
    }

    @MainActor static func available(_ command: Command, in browser: Browser) -> Command? {
        if command.shortcutCommand == .lightTheme {
            // The other of what is on screen: Use System reads as either.
            let dark = browser.prefs.look == .system
                ? NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                : browser.prefs.look == .dark
            return dark ? .lightTheme : .darkTheme
        }
        return variants(of: command).first { $0.available(in: browser) }
    }
}
