import CryptoKit
import SyncKit
import XCTest
@testable import YabPhone

@MainActor
final class TaskApprovalTests: XCTestCase {
    private func makeRequest(_ key: P256.Signing.PrivateKey) -> YesRequest {
        var request = YesRequest(kind: .pay, icon: "", title: "Pay €20?", subtitle: "example.test",
                                 facts: [["Amount", "€20"], ["To", "Test"]], button: "Pay", waiting: "Waiting for you")
        request.approval = TaskApproval(action: .init(account: "test-account", mac: "test-mac", device: "test-phone", task: "task-one",
                                                     session: "session-one", tab: "tab-one", reference: "button-42", url: "https://example.test/pay",
                                                     kind: request.kind.rawValue, title: request.title, subtitle: request.subtitle,
                                                     facts: request.facts, button: request.button),
                                        keyID: TaskApproval.keyID(key.publicKey), nonce: "12345678-1234-4321-ABCD-123456789012", issued: 1000, expires: 1300)
        return request
    }

    func testUnboundRequestCannotReachLiveSigningButExplicitFixtureStillMatchesVirtualMac() throws {
        let key = P256.Signing.PrivateKey(); var request = makeRequest(key)
        request.approval = nil
        XCTAssertThrowsError(try request.approvalDigest(task: "task-one", key: key.publicKey, at: 1001))
        XCTAssertEqual(try request.approvalDigest(task: "task-one", key: key.publicKey, allowsFixture: true, at: 1001), request.digest(task: "task-one"))
    }

    func testDisplayedFactsAndTaskMustMatchTheMacChallengeBeforeSigning() throws {
        let key = P256.Signing.PrivateKey(), request = makeRequest(key)
        XCTAssertEqual(try request.approvalDigest(task: "task-one", key: key.publicKey, at: 1001), try XCTUnwrap(request.approval).digest())
        XCTAssertThrowsError(try request.approvalDigest(task: "other-task", key: key.publicKey, at: 1001))
        var changed = request; changed.facts[0][1] = "€200"
        XCTAssertThrowsError(try changed.approvalDigest(task: "task-one", key: key.publicKey, at: 1001))
        changed = request; changed.button = "Post"
        XCTAssertThrowsError(try changed.approvalDigest(task: "task-one", key: key.publicKey, at: 1001))
    }

    func testForeignKeyAndExpiredChallengeCannotBeSigned() throws {
        let key = P256.Signing.PrivateKey(), request = makeRequest(key)
        XCTAssertThrowsError(try request.approvalDigest(task: "task-one", key: P256.Signing.PrivateKey().publicKey, at: 1001))
        XCTAssertThrowsError(try request.approvalDigest(task: "task-one", key: key.publicKey, at: 1300))
    }

    func testLiveSignerNeverCreatesASoftwareKeyInSimulator() throws {
        #if targetEnvironment(simulator)
        XCTAssertThrowsError(try FaceIDSigner())
        XCTAssertNoThrow(try FaceIDSigner(allowsFixtureRequests: true))
        #endif
    }
}
