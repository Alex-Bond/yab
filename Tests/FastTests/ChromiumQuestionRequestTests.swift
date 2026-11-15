import Foundation
import Testing
@testable import Fast

@Suite(.serialized) @MainActor
struct ChromiumQuestionRequestTests {
    private final class ClientIdentity {}
    private func owner(_ client: ClientIdentity, _ generation: UUID, remote: String = "original-tab",
                       profile: String = "original-profile") -> ChromiumQuestionRequests.Owner {
        .init(client: ObjectIdentifier(client), generation: generation, remote: remote, profile: profile)
    }

    @Test func newHelperReusingBothWireIDsCannotConsumeOriginalPermission() throws {
        let requests = ChromiumQuestionRequests(), first = ClientIdentity(), second = ClientIdentity()
        let firstOwner = owner(first, UUID()), secondOwner = owner(second, UUID())
        let old = try #require(requests.begin(token: "same-request", kind: "capture", owner: firstOwner, reject: {}))
        #expect(!requests.finish(old, owner: secondOwner))
        requests.cancel()
        let new = try #require(requests.begin(token: "same-request", kind: "capture", owner: secondOwner, reject: {}))
        #expect(!requests.finish(old, owner: firstOwner))
        #expect(new.lifetime.isActive)
        #expect(requests.finish(new, owner: secondOwner))
        #expect(!requests.finish(new, owner: secondOwner))
    }

    @Test func generationRemoteAndProfileAreSeparateOwnershipRequirements() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), generation = UUID()
        let original = owner(client, generation)
        let request = try #require(requests.begin(token: "permission", kind: "capture", owner: original, reject: {}))
        #expect(!requests.finish(request, owner: owner(client, UUID())))
        #expect(!requests.finish(request, owner: owner(client, generation, remote: "replacement-tab")))
        #expect(!requests.finish(request, owner: owner(client, generation, profile: "other-profile")))
        #expect(requests.finish(request, owner: original))
    }

    @Test func combinedStopRetiresEveryCaptureButKeepsUnrelatedQuestions() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        var denied = 0, remembered = false, closedCards = 0
        let camera = try #require(requests.begin(token: "camera-child", kind: "capture", owner: identity, reject: { denied += 1 }))
        let microphone = try #require(requests.begin(token: "microphone-child", kind: "capture", owner: identity, reject: { denied += 1 }))
        let location = try #require(requests.begin(token: "location-child", kind: "location", owner: identity, reject: { denied += 100 }))
        camera.lifetime.whenCancelled {
            closedCards += 1
            // A UI reply delivered by withdrawal is already too late.
            if requests.finish(camera, owner: identity) { remembered = true }
        }
        requests.cancel(kind: "capture")
        #expect(denied == 2 && closedCards == 1 && !remembered)
        #expect(!requests.finish(camera, owner: identity))
        #expect(!requests.finish(microphone, owner: identity))
        #expect(location.lifetime.isActive)
        #expect(requests.finish(location, owner: identity))
        requests.cancel(kind: "capture")
        #expect(denied == 2)
    }

    @Test func navigationOrRetirementBeforeQueuedReplyRejectsLateGrant() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        var sentAllow = 0, sentDeny = 0
        let request = try #require(requests.begin(token: "native", kind: "capture", owner: identity, reject: { sentDeny += 1 }))
        // Represents the UI's completion queued for a later MainActor turn.
        let pendingReply = { if requests.finish(request, owner: identity) { sentAllow += 1 } }
        requests.cancel()
        pendingReply(); pendingReply()
        #expect(sentAllow == 0 && sentDeny == 1)
    }

    @Test func duplicateOpenCannotReplaceTheOriginalCallback() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        let original = try #require(requests.begin(token: "native", kind: "capture", owner: identity, reject: {}))
        #expect(requests.begin(token: "native", kind: "auth", owner: identity, reject: {}) == nil)
        #expect(requests.finish(original, owner: identity))
    }

    @Test func lateTCCObserverSeesRetiredLifetimeWithoutRememberingGrant() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        let request = try #require(requests.begin(token: "native", kind: "capture", owner: identity, reject: {}))
        requests.cancel(kind: "capture")
        var withdrawn = false, remembered = false
        request.lifetime.whenCancelled { withdrawn = true }
        if request.lifetime.isActive { remembered = true }
        #expect(withdrawn && !remembered)
        #expect(request.nativeDocument == nil) // No fake native document proof.
    }

    @Test func nativeDismissalWithdrawsExactlyOneOriginalChildQuestionOnce() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        var denied = 0, withdrawn = 0
        let child = try #require(requests.begin(token: "original-child", kind: "location", owner: identity, reject: { denied += 1 }))
        let unrelated = try #require(requests.begin(token: "unrelated-child", kind: "notifications", owner: identity, reject: { denied += 100 }))
        child.lifetime.whenCancelled {
            withdrawn += 1
            #expect(!requests.finish(child, owner: identity))
            #expect(unrelated.lifetime.isActive)
        }
        requests.nativeClosed(token: "original-child", owner: identity)
        requests.nativeClosed(token: "original-child", owner: identity)
        #expect(withdrawn == 1 && denied == 0)
        #expect(!requests.finish(child, owner: identity))
        #expect(requests.finish(unrelated, owner: identity))
    }

    @Test func oldOrForeignDismissalCannotWithdrawNewHelperOrOtherOwner() throws {
        let requests = ChromiumQuestionRequests(), first = ClientIdentity(), next = ClientIdentity(), generation = UUID()
        let oldOwner = owner(first, UUID()), currentOwner = owner(next, generation)
        let request = try #require(requests.begin(token: "same-request", kind: "capture", owner: currentOwner, reject: {}))
        requests.nativeClosed(token: "same-request", owner: oldOwner)
        requests.nativeClosed(token: "same-request", owner: owner(next, generation, remote: "other-tab"))
        requests.nativeClosed(token: "same-request", owner: owner(next, generation, profile: "other-profile"))
        requests.nativeClosed(token: "missing-request", owner: currentOwner)
        #expect(request.lifetime.isActive)
        #expect(requests.finish(request, owner: currentOwner))
    }

    @Test func fullRegistryDeniesNewRequestWithoutDenyingDuplicateOriginal() throws {
        let requests = ChromiumQuestionRequests(), client = ClientIdentity(), identity = owner(client, UUID())
        var overflowDenials = 0
        let first = try #require(requests.begin(token: "0", kind: "capture", owner: identity, reject: {}))
        for index in 1..<128 {
            #expect(requests.begin(token: String(index), kind: "location", owner: identity, reject: {}) != nil)
        }
        #expect(requests.begin(token: "0", kind: "capture", owner: identity, reject: { overflowDenials += 100 }) == nil)
        #expect(first.lifetime.isActive && overflowDenials == 0)
        #expect(requests.begin(token: "new-overflow", kind: "capture", owner: identity, reject: { overflowDenials += 1 }) == nil)
        #expect(first.lifetime.isActive && overflowDenials == 1)
        #expect(requests.finish(first, owner: identity))
        #expect(requests.begin(token: "after-capacity-release", kind: "capture", owner: identity, reject: {}) != nil)
    }
}
