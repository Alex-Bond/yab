import Foundation
import Testing
@testable import Fast
@testable import SyncKit

struct PhoneAskRegressionTests {
    @MainActor @Test func mailQuestionsTravel() {
        #expect(AssistantApprovals.travels(.mailRead))
        #expect(AssistantApprovals.travels(.mailChange(label: "Archive", act: "archive")))
        #expect(AssistantApprovals.travels(.mailSite(host: "example.test")))
        #expect(!AssistantApprovals.travels(.computer))
        #expect(!AssistantApprovals.travels(.unlockManager(provider: "1password")))
    }

    @Test func aMailOperationHasACompatibleAddressWithoutABrowserTab() throws {
        let place = AssistantApprovals.Place.mail(UUID().uuidString.lowercased())
        #expect(AssistantApprovalRecords.Request.validPlace(place.wire))
        let request = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: "account", mac: "mac", assistant: "local.external",
            session: "mail-caller", tab: place.wire, permit: "mail:immutable-outgoing", title: "Claude: Send this mail?",
            lines: ["To person@example.com"], expires: Date().addingTimeInterval(300))
        try request.validate()
    }

    @Test func chatQuestionsHaveAnAddressWithoutATab() throws {
        let request = try AssistantApprovalRecords.Request(
            id: UUID().uuidString.lowercased(), account: "account", mac: "mac", assistant: "local.external",
            session: "child", tab: "chat:root", permit: "mail.read", title: "Claude: Search your mail?",
            lines: ["Travel", "once for this chat"], expires: Date().addingTimeInterval(300))
        let record = Record(collection: AssistantApprovalRecords.requestCollection, id: request.id,
                            fields: try request.fields(), stamps: ["body": Stamp(wall: 1, device: "mac")])
        #expect(try AssistantApprovalRecords.Request.read(record, account: "account", mac: "mac") == request)
        let answer = try AssistantApprovalRecords.Answer(request: request, device: "phone", yes: true)
        try answer.validate(request: request)
    }
}
