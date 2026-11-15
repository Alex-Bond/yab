import Foundation
import WebKit

/// What a page may do with a person's tap, beyond what WebKit decides. WebKit
/// on iOS already refuses a window nobody tapped for, and a frame of another
/// site sending the whole page away with no tap. These are the ways around
/// that, which spend a tap meant for something else:
///
/// - a second window from one tap: one tap, one window;
/// - a script in another site's frame, an advertisement's most often,
///   opening a third site or sending the page there;
/// - the tab-under: a page that opened a window goes to another site while
///   the person looks at that window, Chrome's rule for the same trick.
///
/// A link is never judged: the person pressed it and it says where it goes.
/// Nor is a page sending itself elsewhere with no window opened: sign-ins,
/// payments and link shorteners all do that, and nothing tells them from an
/// advertisement's redirect. A window with nowhere to go yet opens: payment
/// buttons in frames fill theirs a moment later.
enum PageWindows {
    /// What the frame asking is, seen from the page it is on.
    struct Asker: Equatable, Sendable {
        /// Its site, nil for an opaque origin. Only set for a frame inside
        /// the page: a page's own main frame is never another site's.
        var frame: String?
        var isSubframe: Bool
    }

    /// The window a page asks for opens. `spent`: this tap already opened one.
    static func opens(link: Bool, spent: Bool, asker: Asker, page: String?, going: String?) -> Bool {
        if link { return true }
        return !spent && !foreign(asker, page: page, going: going)
    }

    /// The main frame goes where it was sent. `behind`: it opened a window
    /// on the tap that started this, and nothing has touched it since.
    static func follows(navigation: WKNavigationType, asker: Asker, page: String?, going: String?, behind: Bool) -> Bool {
        guard navigation == .other, let page, let going, going != page else { return true }
        return !behind && !foreign(asker, page: page, going: going)
    }

    /// Another site's frame heading for a third site.
    private static func foreign(_ asker: Asker, page: String?, going: String?) -> Bool {
        guard asker.isSubframe, let going else { return false }
        return asker.frame != page && going != asker.frame && going != page
    }

    /// A host's site: its last two labels, a whole address for an IP. Under
    /// a two-part suffix (co.uk) two sites read as one, which only ever
    /// leaves a page unjudged.
    static func site(of host: String?) -> String? {
        guard var host = host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".")
        guard !host.contains(":"), labels.count > 2, labels.last?.allSatisfy(\.isNumber) == false else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    /// The site of a web address, nil for about:, data: and the like.
    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return site(of: url.host())
    }

    /// The frame that asked. WebKit can leave it out, which Swift's
    /// non-optional property doesn't allow for.
    static func asker(_ action: WKNavigationAction) -> Asker {
        guard let frame = action.value(forKey: "sourceFrame") as? WKFrameInfo, !frame.isMainFrame else {
            return Asker(frame: nil, isSubframe: false)
        }
        return Asker(frame: site(of: frame.securityOrigin.host), isSubframe: true)
    }
}
