import Testing
@testable import Fast

@MainActor @Suite(.serialized)
struct ExtensionDownloadNamingTests {
    @Test func waitsForEveryExtensionAndUsesInstallationOrderRatherThanReplyOrder() throws {
        var replies: [String?] = []
        let request = try #require(ExtensionDownloadNaming.begin(extensions: ["older", "newer"]) { replies.append($0) })
        ExtensionDownloadNaming.suggest(request, by: "unrelated", filename: "wrong.png")
        ExtensionDownloadNaming.suggest(request, by: "newer", filename: "Pictures/actual.png")
        #expect(replies.isEmpty)
        ExtensionDownloadNaming.suggest(request, by: "older", filename: "older.png")
        #expect(replies.count == 1 && replies[0] == "Pictures/actual.png")
        ExtensionDownloadNaming.suggest(request, by: "newer", filename: "duplicate.png")
        #expect(replies.count == 1)
    }

    @Test func unloadAndCancellationReleasePendingRepliesAndRejectTraversal() throws {
        var replies: [String?] = []
        let request = try #require(ExtensionDownloadNaming.begin(extensions: ["one", "two"]) { replies.append($0) })
        ExtensionDownloadNaming.suggest(request, by: "one", filename: "../outside.png")
        ExtensionDownloadNaming.unloaded("two")
        #expect(replies.count == 1 && replies[0] == nil)
        let canceled = try #require(ExtensionDownloadNaming.begin(extensions: ["one"]) { replies.append($0) })
        ExtensionDownloadNaming.cancel(canceled)
        ExtensionDownloadNaming.suggest(canceled, by: "one", filename: "late.png")
        #expect(replies.count == 2 && replies[1] == nil)
    }
}
