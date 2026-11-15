import AppKit
import MailCore

// The bench's Files and Purchases world (`box` seed-shelf): what the
// concept draws, made real in a test world, for probes and evals.

extension Bench {
    @MainActor static func seedShelf(_ browser: Browser) -> [String: Any] {
        let folder = Store.file("seeded-shelf")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date()
        let day: TimeInterval = 86_400
        func pdf(_ name: String, _ lines: [String]) -> URL {
            let url = folder.appendingPathComponent(name)
            var box = CGRect(x: 0, y: 0, width: 612, height: 792)
            guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return url }
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            var y: CGFloat = 720
            for (index, line) in lines.enumerated() {
                let font = NSFont.systemFont(ofSize: index == 0 ? 18 : 12, weight: index == 0 ? .bold : .regular)
                (line as NSString).draw(at: CGPoint(x: 64, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
                y -= index == 0 ? 36 : 20
            }
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
            context.closePDF()
            return url
        }
        let lease = pdf("Lease agreement, signed.pdf", ["RESIDENTIAL LEASE", "Between Ivan Petrov (Landlord) and the Tenant.",
                                                        "Term: November 1, 2026 to October 31, 2027.",
                                                        "Rent: $3,200 a month, due on the first.",
                                                        "The security deposit of $3,200 is due before move-in.", "Signed: Ivan Petrov"])
        let w9 = pdf("W-9 2026.pdf", ["Form W-9", "Request for Taxpayer Identification Number and Certification"])
        let pass = pdf("Boarding pass, SFO.pdf", ["UNITED", "New York to San Francisco, November 10", "Seat 14C"])
        let scan = folder.appendingPathComponent("passport-scan.jpg")
        if let image = NSImage(size: NSSize(width: 600, height: 400), flipped: false, drawingHandler: { rect in
            NSColor(calibratedRed: 0.6, green: 0.75, blue: 0.9, alpha: 1).setFill()
            rect.fill()
            return true
        }).tiffRepresentation, let bitmap = NSBitmapImageRep(data: image), let jpeg = bitmap.representation(using: .jpeg, properties: [:]) {
            try? jpeg.write(to: scan)
        }
        func mail(_ url: URL, from: String, address: String, to: String = "", subject: String, sent: Bool = false, ago: Double) -> ShelfFile {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            let message = "seed-" + String(url.lastPathComponent.hashValue.magnitude)
            return ShelfFile(id: "mail.me@yab.test|\(message)|1", name: url.lastPathComponent, date: now.addingTimeInterval(-ago * day), size: size,
                             origin: .mail(account: "me@yab.test", message: message, thread: message, from: MailPerson(name: from, address: address),
                                           to: to.isEmpty ? [] : [MailPerson(name: to, address: "anna@brightkeys.test")], subject: subject, sent: sent),
                             file: nil, path: url.path)
        }
        let shelf = FileShelf.shared
        shelf.testingMail = [
            mail(pass, from: "United Airlines", address: "receipts@united.test", subject: "Your boarding pass", ago: 1),
            mail(lease, from: "Ivan Petrov", address: "ivan@landlord.test", subject: "Re: Lease, signed copy", ago: 3),
            mail(w9, from: "Me", address: "me@yab.test", to: "Anna Lee", subject: "W-9 for the lease", sent: true, ago: 5),
        ]
        shelf.refresh(force: true)
        if shelf.given(to: "united.com").isEmpty { shelf.gave([scan], to: "united.com") }

        func sub(_ merchant: String, _ host: String, _ title: String, _ amount: Double, _ period: MailPurchase.Period, renews: Double, opened: Double?,
                 card: String = "4411", brand: String = "Visa", canceled: Bool = false) -> (purchase: MailPurchase, account: String, opened: Date?) {
            (MailPurchase(kind: .subscription, message: "seed-" + merchant, thread: "seed-" + merchant,
                          date: now.addingTimeInterval((renews - (period == .year ? 365 : 30)) * day), merchant: merchant, host: host, title: title,
                          amount: amount, currency: "USD", period: period, card: card, brand: brand,
                          renews: canceled ? nil : now.addingTimeInterval(renews * day), ends: canceled ? now.addingTimeInterval(renews * day) : nil,
                          canceled: canceled),
             "me@yab.test", opened.map { now.addingTimeInterval(-$0 * day) })
        }
        Purchases.shared.testing = [
            sub("Anthropic", "claude.ai", "Claude Max", 100, .month, renews: 12, opened: 0),
            sub("Figma", "figma.com", "Figma Professional", 180, .year, renews: 0.8, opened: 41),
            sub("Netflix", "netflix.com", "Netflix Standard", 15.49, .month, renews: 6, opened: 1, card: "1008", brand: "Amex"),
            sub("Headspace", "headspace.com", "Headspace", 12.99, .month, renews: 15, opened: 70),
            sub("Spotify", "spotify.com", "Spotify Premium", 11.99, .month, renews: 3, opened: 0),
            sub("Notion", "notion.so", "Notion Plus", 10, .month, renews: 11, opened: 34),
            sub("Google", "one.google.com", "Google One", 9.99, .month, renews: 20, opened: 2),
            (MailPurchase(kind: .order, message: "seed-airpods", thread: "seed-airpods", date: now.addingTimeInterval(-2 * day), merchant: "Apple",
                          host: "apple.com", title: "AirPods Pro 3", amount: 249, currency: "USD", order: "W1288", tracking: "1Z999AA10123456784",
                          carrier: "UPS", shipping: .outForDelivery, arrives: now.addingTimeInterval(6 * 3600)), "me@yab.test", nil),
            (MailPurchase(kind: .order, message: "seed-keychron", thread: "seed-keychron", date: now.addingTimeInterval(-1 * day), merchant: "Keychron",
                          host: "keychron.com", title: "Keychron Q1 Max", amount: 219, currency: "USD", tracking: "9400111899223197428490",
                          carrier: "USPS", shipping: .shipped, arrives: now.addingTimeInterval(3 * day)), "me@yab.test", nil),
            (MailPurchase(kind: .receipt, message: "seed-macbook", thread: "seed-macbook", date: now.addingTimeInterval(-322 * day), merchant: "Apple",
                          host: "apple.com", title: "MacBook Pro 14-inch", amount: 2_499, currency: "USD", card: "4411", brand: "Visa", order: "W9921"),
             "me@yab.test", nil),
        ]
        Purchases.shared.refresh(force: true)
        return ["ok": true, "files": shelf.mail.count + shelf.uploads.count, "subscriptions": Purchases.shared.subscriptions.count,
                "orders": Purchases.shared.orders.count]
    }
}
