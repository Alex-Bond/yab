import Foundation
import Testing
@testable import Fast

extension NativeAppleModelTests {
    /// Disabled entrypoints only: no Browser, account, provider or model is started.
    @MainActor
    struct AppleModelExecutionTests {
        @Test func disabledModelRejectsDirectAndQueuedFallbackEntrypoints() async throws {
            try #require(Store.testing && Store.world != nil)
            try #require(Store.settings !== UserDefaults.standard)
            let defaults = Store.settings
            let previous = defaults.object(forKey: AppleModelAccess.disabledKey)
            defer {
                if let previous { defaults.set(previous, forKey: AppleModelAccess.disabledKey) }
                else { defaults.removeObject(forKey: AppleModelAccess.disabledKey) }
                NotificationCenter.default.post(name: AppleModelAccess.changed, object: nil)
            }
            AppleModelAccess.setEnabled(false, in: defaults)

            #expect(!FormModel.ready)
            #expect(!MailSense.ready)
            #expect(FormModel.why == "Apple Intelligence is disabled in Yab")
            #expect(await FormModel.Asker().ask("Fixture label") == "none")
            #expect(await ShortNames.model("Fixture title") == nil)
            #expect(await ChatTitles.model("Fixture question") == nil)
            #expect(await LinkFolders.model(["Fixture one", "Fixture two"]) == nil)
            #expect(await TidyTabs.model("Fixture tabs") == nil)
            #expect(await LinkSummary.gist(LinkSummary.Page(title: "Fixture", text: "Owned fixture")) == nil)
            #expect(await ThreadNamer.mac("Fixture thread") == nil)
            #expect(await SystemReader.read("Fixture words", people: [], hosts: []) == nil)
            #expect(await SystemReader.pick("Fixture", options: ["Fixture"]) == nil)

            var partials = 0
            do {
                try await MacAnswer.stream("Fixture", page: "Fixture page", selection: nil) { _ in partials += 1 }
                Issue.record("Disabled MacAnswer must return unavailable before inference")
            } catch MacAnswer.Failure.unavailable {
                #expect(partials == 0)
            }

            let message = MailMessage(id: "apple-model-disabled", thread: "fixture",
                                      from: MailPerson(name: "Fixture", address: "fixture@example.invalid"),
                                      subject: "Owned fixture", date: Date(timeIntervalSince1970: 1), text: "Fixture body")
            #expect(await MailSense.Reader().read(message) == nil)
        }
    }
}
