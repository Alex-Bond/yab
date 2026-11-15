import UIKit
import WebKit

/// One native challenge, scoped to the actual foreground document and jar.
/// Credentials are supplied to WebKit once and are never saved by the app.
@MainActor
final class PageHTTPAuthentication {
    let id = UUID()
    let tab: Tab.ID
    weak var webView: WKWebView?
    weak var navigation: WKNavigation?
    let document: UUID
    let url: URL?
    let requestedURL: String?
    let store: ObjectIdentifier
    let privateSession: UUID?
    let controller: UIAlertController
    private var completion: (@MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)?

    init(tab: Tab.ID, webView: WKWebView, navigation: WKNavigation?, document: UUID,
         requestedURL: String?, privateSession: UUID?, site: String,
         completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        self.tab = tab; self.webView = webView; self.navigation = navigation; self.document = document
        self.url = webView.url; self.requestedURL = requestedURL
        self.store = ObjectIdentifier(webView.configuration.websiteDataStore)
        self.privateSession = privateSession; self.completion = completion
        controller = UIAlertController(title: "Sign In to \(site)",
            message: "This website requires a username and password.", preferredStyle: .alert)
        controller.addTextField { field in
            field.placeholder = "Username"; field.textContentType = .username
            field.autocapitalizationType = .none; field.autocorrectionType = .no
            field.accessibilityIdentifier = "page.authentication.username"
            field.accessibilityLabel = "Website username"
        }
        controller.addTextField { field in
            field.placeholder = "Password"; field.textContentType = .password
            field.isSecureTextEntry = true
            field.accessibilityIdentifier = "page.authentication.password"
            field.accessibilityLabel = "Website password"
        }
    }

    func resolve(user: String?, password: String?, animated: Bool) {
        guard let completion else { return }
        self.completion = nil
        let credential: URLCredential?
        if let user, let password { credential = URLCredential(user: user, password: password, persistence: .none) }
        else { credential = nil }
        controller.textFields?.forEach { $0.text = nil }
        let disposition: URLSession.AuthChallengeDisposition = credential == nil ? .cancelAuthenticationChallenge : .useCredential
        if controller.presentingViewController != nil {
            controller.dismiss(animated: animated) { completion(disposition, credential) }
        } else { completion(disposition, credential) }
    }

    static func matches(_ space: URLProtectionSpace, url: URL) -> Bool {
        guard !space.isProxy(), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              space.protocol?.lowercased() == scheme, space.host.caseInsensitiveCompare(url.host ?? "") == .orderedSame
        else { return false }
        return space.port == (url.port ?? (scheme == "https" ? 443 : 80))
    }
}
