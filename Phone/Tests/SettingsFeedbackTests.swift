import Foundation
import XCTest
@testable import YabPhone

/// The same request and completion path as Settings, with no production writes.
@MainActor
final class SettingsFeedbackTests: XCTestCase {
    private let site = URL(string: "https://feedback.example")!

    func testRequestCarriesTheDraftOptionalEmailAndIPhoneBuildToTheInboxEndpoint() throws {
        let request = SettingsFeedbackView.request(message: "A page stopped loading.\nPlease check.", email: "  tester@example.com  ", site: site)
        XCTAssertEqual(request.url?.absoluteString, "https://feedback.example/api/feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 15)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(Set(fields.keys), ["kind", "message", "email", "version", "build", "os"])
        XCTAssertEqual(fields["kind"], "other")
        XCTAssertEqual(fields["message"], "A page stopped loading.\nPlease check.")
        XCTAssertEqual(fields["email"], "tester@example.com")
        XCTAssertEqual(fields["version"], SettingsStore.version())
        XCTAssertEqual(fields["build"], SettingsStore.build())
        XCTAssertTrue(fields["os"]?.hasPrefix("iOS ") == true)
        XCTAssertEqual(SettingsFeedbackView.fields(message: "No email", email: "  ")["email"], "")
    }

    func testAcceptanceClearsTheDraftOnlyAfterTheServerResponds() async {
        let ui = SettingsUI()
        ui.feedbackDraft = "Keep this until accepted."
        let session = session(status: 200)
        defer { session.invalidateAndCancel() }
        let result = await SettingsFeedbackView.submit(request(ui), session: session, ui: ui)
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(ui.feedbackDraft, "")
    }

    func testServerRejectionKeepsTheDraftForRetry() async {
        for status in [400, 429, 500] {
            let ui = SettingsUI()
            ui.feedbackDraft = "Keep this for retry."
            let session = session(status: status)
            let result = await SettingsFeedbackView.submit(request(ui), session: session, ui: ui)
            session.invalidateAndCancel()
            XCTAssertEqual(result, .failed("The site didn't take it. Your draft is still here."))
            XCTAssertEqual(ui.feedbackDraft, "Keep this for retry.")
        }
    }

    func testConnectionFailureKeepsTheDraftForRetry() async {
        let ui = SettingsUI()
        ui.feedbackDraft = "An offline draft."
        let session = session(status: nil)
        defer { session.invalidateAndCancel() }
        let result = await SettingsFeedbackView.submit(request(ui), session: session, ui: ui)
        XCTAssertEqual(result, .failed("Couldn't reach Yab's site. Your draft is still here."))
        XCTAssertEqual(ui.feedbackDraft, "An offline draft.")
    }

    private func request(_ ui: SettingsUI) -> URLRequest {
        SettingsFeedbackView.request(message: ui.feedbackDraft, email: "", site: site)
    }

    private func session(status: Int?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsFeedbackProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Feedback-Test-Status": status.map(String.init) ?? "offline"]
        return URLSession(configuration: configuration)
    }
}

private final class SettingsFeedbackProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "feedback.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let status = request.value(forHTTPHeaderField: "X-Feedback-Test-Status").flatMap(Int.init) else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
