import Foundation
import Testing
@testable import MailCore

struct MailExperimentTests {
    @Test func existingMailDoesNotOptIntoTheExperiment() throws {
        let suite = "mail-experiment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "mail")
        defaults.set(["kept@example.com"], forKey: "mail.accounts")
        #expect(!MailExperiment.enabled(in: defaults))
        defaults.set(true, forKey: MailExperiment.key)
        #expect(MailExperiment.enabled(in: defaults))
        defaults.set(false, forKey: MailExperiment.key)
        #expect(!MailExperiment.enabled(in: defaults))
        #expect(defaults.stringArray(forKey: "mail.accounts") == ["kept@example.com"])
    }

    @Test(arguments: [false, true])
    func mailEnablesEveryProviderRegardlessOfRetiredFlag(_ retiredFlag: Bool) throws {
        let suite = "mail-experiment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(retiredFlag, forKey: "experimental.mail.imap")
        defaults.set(true, forKey: "mail")
        defaults.set(true, forKey: MailExperiment.key)
        #expect(MailExperiment.otherAccounts(in: defaults))
        defaults.set(false, forKey: MailExperiment.key)
        #expect(!MailExperiment.otherAccounts(in: defaults))
        defaults.set(true, forKey: MailExperiment.key)
        defaults.set(false, forKey: "mail")
        #expect(!MailExperiment.otherAccounts(in: defaults))
    }

    @Test func freshMailOptInIncludesOtherAccounts() throws {
        let suite = "mail-experiment-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "mail")
        #expect(!MailExperiment.otherAccounts(in: defaults))
        defaults.set(true, forKey: MailExperiment.key)
        #expect(MailExperiment.otherAccounts(in: defaults))
    }

}
