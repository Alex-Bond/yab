import Foundation

/// The ways into Yab from outside it, not prototype frames: the share
/// sheet's card (share.1-3) and the Search and Ask widgets on the Home
/// Screen and the Lock Screen (widgets.1-3), drawn with the extensions' own
/// views over stand-ins of the system's screens (EntrancePictures).
extension StateCatalog {
    static let entrances: [NamedState] = [
        NamedState("share.1", "Share: a link", "Yab in another app's share sheet: the page, Keep for Later and Open in Yab.") { _ in
            EntrancePictures.show(.share(EntranceSamples.link, .ready))
        },
        NamedState("share.2", "Share: words", "Text without a link: Search in Yab alone.") { _ in
            EntrancePictures.show(.share(EntranceSamples.words, .ready))
        },
        NamedState("share.3", "Share: kept", "Keep for Later says so where the buttons were, then the sheet goes.") { _ in
            EntrancePictures.show(.share(EntranceSamples.link, .kept))
        },
        NamedState("widgets.1", "Widgets: Home Screen", "Search and Ask, small: Yab's mark over New Tab's field.") { _ in
            EntrancePictures.show(.homeScreen)
        },
        NamedState("widgets.2", "Widgets: Lock Screen, Search", "Search rectangular, then Search and Ask round, under the clock.") { _ in
            EntrancePictures.show(.lockScreen(.search))
        },
        NamedState("widgets.3", "Widgets: Lock Screen, Ask", "Ask rectangular, then Search and Ask round, under the clock.") { _ in
            EntrancePictures.show(.lockScreen(.ask))
        },
        NamedState("widgets.4", "Now widget: as it fills", "Medium with nothing (Search and Ask), one row, two rows.") { _ in
            EntrancePictures.show(.now(few: true))
        },
        NamedState("widgets.5", "Now widget: full", "Medium with three rows, the small with a row and with nothing, the Lock Screen's.") { _ in
            EntrancePictures.show(.now(few: false))
        },
    ]
}

/// What the pictures share: Mira's Lumen link, as Telegram shares it, and
/// words without a link.
enum EntranceSamples {
    static let link = SharedItems.Found(address: "https://lumen.events/e/design-systems-night", search: false,
                                        title: "Design Systems Night \u{00B7} Stockholm")
    static let words = SharedItems.Found(address: "quiet cafes near Södermalm open late", search: true, title: nil)
    /// A Mac's Now rows about mail, as Noticing words them.
    static let nowRows = [
        NowShelfRow(id: "mail.t1", title: "Danny says autofill still shows NordPass locked", detail: "12m · Re: NordPass on Yab",
                    who: "Danny", host: "gmail.com", web: "https://mail.google.com/mail/u/me@example.com/#all/t1",
                    message: "<t1@mail.gmail.com>", order: 0),
        NowShelfRow(id: "mail.t2", title: "Chase card payment $1,240", detail: "Chase · today 12:00", who: "Chase",
                    host: "chase.com", web: nil, message: nil, order: 1),
        NowShelfRow(id: "mail.t3", title: "Mark is waiting on what you promised", detail: "Fri · Invite links for the team",
                    who: "Mark", host: "example.com", web: nil, message: nil, order: 2),
    ]
}
