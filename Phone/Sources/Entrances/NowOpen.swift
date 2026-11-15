import UIKit

// A Now widget row's tap (yab://now?id=<row>). Yab has no mail on the
// iPhone, so the thread opens in the mail app you use: Gmail's own app
// takes its thread link when it is installed, else Mail finds the message
// by its Message-ID, else the thread opens in Gmail on the web, in a new tab.

extension AppModel {
    /// True when the link was a Now row's, opened or gone.
    @discardableResult
    func openNow(_ url: URL, shelf: NowShelf = .shared) -> Bool {
        guard let id = NowShelf.id(in: url) else { return false }
        guard let row = shelf.read().first(where: { $0.id == id }) else { return true }
        let web = row.web.flatMap(URL.init(string:))
        let mail = NowOpen.mailLink(row.message)
        func onWeb() { if let web { self.openFromOutside(web) } }
        guard let web else {
            if let mail { UIApplication.shared.open(mail) }
            return true
        }
        UIApplication.shared.open(web, options: [.universalLinksOnly: true]) { opened in
            guard !opened else { return }
            guard let mail else { return onWeb() }
            UIApplication.shared.open(mail) { opened in if !opened { onWeb() } }
        }
        return true
    }
}

enum NowOpen {
    /// Mail's link to a message by its Message-ID: message://%3Cid%3E.
    static func mailLink(_ messageID: String?) -> URL? {
        guard var id = messageID?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return nil }
        if !id.hasPrefix("<") { id = "<" + id + ">" }
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: ".-_@"))) else { return nil }
        return URL(string: "message://" + encoded)
    }
}
