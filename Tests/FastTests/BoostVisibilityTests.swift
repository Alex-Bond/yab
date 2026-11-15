import Foundation
import Testing
import WebKit
@testable import Fast

@MainActor
struct BoostVisibilityTests {
    @Test func checksRecognizeDisplayContentsAndHiddenAncestors() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        defer { web.stopLoading() }
        web.loadHTMLString("<main style='display:contents'><p>Visible article</p></main><aside style='display:none'><div id='hidden'>Hidden</div></aside>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await BoostJavaScript.evaluate("!!document.querySelector('main')", on: web)) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let visible = BoostScript.visibility
        #expect((try await BoostJavaScript.evaluate("(\(visible))(document.querySelector('main'))", on: web)) as? Bool == true)
        #expect((try await BoostJavaScript.evaluate("(\(visible))(document.querySelector('#hidden'))", on: web)) as? Bool == false)
        _ = try await BoostJavaScript.evaluate("document.querySelector('main').style.visibility='hidden'", on: web)
        #expect((try await BoostJavaScript.evaluate("(\(visible))(document.querySelector('main'))", on: web)) as? Bool == false)
    }
}
