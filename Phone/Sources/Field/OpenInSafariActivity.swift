import UIKit

/// Share › Open in Safari. A plain https address goes to the default
/// browser, which is often Yab itself: the sheet closed and nothing happened
/// (#2035). Safari's own x-safari- scheme (iOS 17+) opens it there.
final class OpenInSafariActivity: UIActivity {
    private var address: URL?

    override class var activityCategory: UIActivity.Category { .action }
    override var activityType: UIActivity.ActivityType? { UIActivity.ActivityType("dev.serafim.fast.iphone.open-in-safari") }
    override var activityTitle: String? { "Open in Safari" }
    override var activityImage: UIImage? { UIImage(systemName: "safari") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool {
        activityItems.contains { Self.safari($0 as? URL) != nil }
    }

    override func prepare(withActivityItems activityItems: [Any]) {
        address = activityItems.lazy.compactMap { Self.safari($0 as? URL) }.first
    }

    override func perform() {
        guard let address else { activityDidFinish(false); return }
        UIApplication.shared.open(address) { [weak self] opened in self?.activityDidFinish(opened) }
    }

    /// The address Safari takes: http(s) only, as x-safari-http(s).
    static func safari(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "x-safari-" + scheme
        return parts.url
    }
}
