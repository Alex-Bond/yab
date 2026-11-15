import Testing
@testable import Fast

struct ProductHelpTests {
    @Test func appearanceIsFoundInBothSearches() {
        for query in ["appearance", "apperance", "apper", "appearance settings"] {
            #expect(SettingsPage.appearance.score(query) != nil, "Cmd+T: \(query)")
        }
        for query in ["appearance", "apperance", "apper"] {
            #expect(SettingsPage.appearance.found(query) != nil, "Settings: \(query)")
        }
        #expect(SettingsPage.appearance.score("appearance")! >= 2)
        #expect(SettingsPage.appearance.score("a") == nil)
        #expect(SettingsPage.appearance.score("unrelated words") == nil)
        #expect(SettingsPage.passwords.score("passwords settings") == SettingsPage.passwords.score("passwords"))
    }

    @MainActor @Test func referenceCoversEverySettingAndCommand() {
        let brief = Guide.productBrief
        for item in SettingsItem.all where item.page != .shortcuts {
            #expect(brief.contains(item.title), "Missing setting: \(item.title)")
        }
        for command in Command.allCases {
            #expect(brief.contains(command.title), "Missing command: \(command.title)")
        }
        #expect(brief.contains("no separate font-size preference"))
        #expect(brief.contains("Zoom is remembered per site"))
    }

    @MainActor @Test func fieldAnswerHasHelpWithoutInstructionsForUnavailableTools() {
        let brief = Agents.instructions(textOnly: true, full: false, remembering: true)
        #expect(brief.contains("This conversation has no tools"))
        #expect(brief.contains("Settings > Appearance"))
        #expect(!brief.contains("call computer_access"))
        #expect(!brief.contains("`history`"))
        #expect(!brief.contains("`memory_search`"))
        #expect(!brief.contains("`skill`"))
    }

    @MainActor @Test func sideChatKeepsBrowserPermissionsAndProductHelp() {
        let brief = Agents.instructions(textOnly: false, full: false, remembering: false)
        #expect(brief.contains("call computer_access"))
        #expect(brief.contains("Settings > Appearance"))
        #expect(brief.contains(Guide.manualURL.absoluteString))
    }

    @Test func manualIsNamedInEnglish() {
        for query in ["manual", "help", "guide", "documentation"] {
            #expect(CommandTests.best(query) == .manual, "\(query)")
        }
        #expect(Command.manual.opens)
    }

    /// Mail's pages of the manual (fast-web's app/manual/topics/mail.tsx),
    /// so a question about mail is pointed at the page that answers it.
    @Test func helpNamesMailsPages() {
        for page in ["mail-triage", "mail-writing", "mail-snippets", "mail-reminders", "mail-search", "mail-splits",
                     "mail-cleanup", "mail-calendar", "mail-notifications", "mail-ask"] {
            #expect(Guide.productOverview.contains("/manual/\(page);") || Guide.productOverview.contains("/manual/\(page)."),
                    "\(page)")
        }
        #expect(Guide.productOverview.contains("/manual/mail;"))
    }

    /// An agent asked to send a mail looked for mail_draft's draft in
    /// Gmail, found none, and drove Yab's window by screen control instead
    /// (Oct 8): the guide says where a draft is, that mail_send sends a mail
    /// the user asked for, and that Yab's windows are never driven.
    @MainActor @Test func guideSaysHowAMailIsSentAndNeverByScreen() {
        #expect(Guide.productOverview.contains("not in Gmail's Drafts"))
        #expect(Guide.productOverview.contains("mail_send sends"))
        #expect(Guide.main.contains("Use Yab's tools, not desktop keystrokes, Computer Use or AppleScript, to control its tabs."))
    }
}
