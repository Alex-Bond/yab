import Foundation
import SyncKit

// From iPhone, on this Mac (docs/sync.md, "Continue from your iPhone"): the
// page in front on an iPhone of the account, as its presence says it, is
// offered under the empty field for a minute after it changed there
// (PhoneFront), the mirror of the iPhone's "On your Mac". Taken, it is the
// tab already showing it, in the space it is in there, as Open on Mac is.

extension SyncCenter {
    /// Another device's presence, heard on the line: an iPhone's page in
    /// front, kept for the field's From iPhone row.
    func heardPresence(_ device: String, _ record: SyncKit.Record) {
        guard device != Self.deviceID else { return }
        if !devices.contains(where: { $0.id == device }) { refreshDevicesSoon() }
        let page = PhoneFront.page(device: device, record: record)
        guard phoneFronts[device] != page else { return }
        phoneFronts[device] = page
        Hints.shared.compose()
        // Composed again as its minute ends, so an open field lets it go.
        if let page {
            let left = page.changed.addingTimeInterval(PhoneFront.window).timeIntervalSinceNow
            if left > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + left + 0.5) { Hints.shared.compose() }
            }
        }
    }

    /// The iPhone page offered now, if any (PhoneFront.offered).
    func phoneOffer(now: Date, in browser: Browser?) -> PhoneFront.Page? {
        let front = browser?.active.flatMap { $0.shy || $0.isBlank ? nil : $0 }
        return PhoneFront.offer(Array(phoneFronts.values), now: now, front: front?.address, frontTab: front?.id.uuidString)
    }
}

extension SyncPhones {
    /// The From iPhone row under the empty field: the page's title, and in
    /// gray which iPhone.
    nonisolated static func hint(_ page: PhoneFront.Page) -> Hint {
        let host = Hints.host(page.url.host() ?? "")
        let name = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return Hint(id: "noticed.phone." + Hints.place(page.url.absoluteString), icon: .site(host), title: page.title,
                    detail: "From \(name.isEmpty ? "iPhone" : name)", url: page.url, source: .noticed,
                    kind: Noticing.Kind.phone.rawValue, phone: page.changed, space: page.space)
    }
}
