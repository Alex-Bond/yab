import Foundation
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// The approval tray's named states (docs/approvals.md, "On the iPhone"):
/// every kind a Mac asks about, every step of a payment, a row open as its
/// window, a file's page full screen, what came of a yes, and frames held in
/// the middle of each movement. The Mac is the bridge's pretend one: its
/// question and detail go through the same tray a real one's do.
extension StateCatalog {
    static let approvals: [NamedState] = kinds + payment + reading + held

    // MARK: - every kind

    private static let kinds: [NamedState] = [
        NamedState("approval.pay", "Pay", "The card, where it goes, the total, Pay with Face ID.") { app in
            await ApprovalFixtures.ask(app, .pay)
        },
        NamedState("approval.mails", "Several mails", "Three mails as rows: who, subject, first words; Send All 3.") { app in
            await ApprovalFixtures.ask(app, .mails)
        },
        NamedState("approval.mail", "One mail", "Its paper: To, Subject, six lines and Show All.") { app in
            await ApprovalFixtures.ask(app, .mail)
        },
        NamedState("approval.archive", "Archive mail", "Three rows and 11 more, in a chat; Archive 14.") { app in
            await ApprovalFixtures.ask(app, .archive)
        },
        NamedState("approval.files", "Upload", "The files' pages, names and sizes; Upload 2 Files.") { app in
            await ApprovalFixtures.ask(app, .files)
        },
        NamedState("approval.message", "iMessage", "The person and the bubble it will be; Send.") { app in
            await ApprovalFixtures.ask(app, .message)
        },
        NamedState("approval.signin", "Sign in", "One row an account; a tap on one is the yes.") { app in
            await ApprovalFixtures.ask(app, .signIn)
        },
        NamedState("approval.lines", "From an older Mac", "No detail came: the Mac's lines, the question, Approve.") { app in
            await ApprovalFixtures.ask(app, .lines)
        },
        NamedState("approval.mails.old", "Mails from an older Mac", "No detail came: rows read out of the Mac's lines; Approve.") { app in
            await ApprovalFixtures.ask(app, .oldMails)
        },
        NamedState("approval.search", "Search your mail", "The first search as a field, every one after it in the chat; Allow in This Chat.") { app in
            await ApprovalFixtures.ask(app, .search)
        },
        NamedState("approval.search.old", "Search, older Mac", "No detail came: the scope alone; Allow in This Chat.") { app in
            await ApprovalFixtures.ask(app, .searchOld)
        },
        NamedState("approval.queue", "Two waiting", "1 of 2 in the head; the next comes once this one goes.") { app in
            await ApprovalFixtures.ask(app, .pay, also: .mails)
        },
    ]

    // MARK: - a payment's steps

    private static let payment: [NamedState] = [
        NamedState("approval.pay.cards", "Pay With", "The cards in Yab, the one picked ticked, Add Card…") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.go(.cards)
        },
        NamedState("approval.pay.places", "Ship To", "The addresses in Yab, Add Address…") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.go(.places)
        },
        NamedState("approval.pay.newCard", "Add Card", "The form filled, Save Card ready, over the keyboard.") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.go(.cards)
            await ApprovalFixtures.wait(0.4)
            tray.go(.newCard)
            tray.cardForm = .init(number: "4242 4242 4242 4242", expires: "08 / 29", csc: "123", name: "Sam Rivera")
        },
        NamedState("approval.pay.newPlace", "Add Address", "The address form filled, Save Address ready.") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.go(.places)
            await ApprovalFixtures.wait(0.4)
            tray.go(.newPlace)
            tray.placeForm = .init(name: "Sam Rivera", street: "1 Main St", apt: "Apt 4", city: "Brooklyn", postal: "11201")
        },
        NamedState("approval.pay.picked", "Another card", "Amex picked: back on the first body, its row lit.") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.pickCard("c2")
        },
        NamedState("approval.pay.paying", "Paying", "Paying on amazon.com, its arc running.") { app in
            await ApprovalFixtures.payThen(app, .paying)
        },
        NamedState("approval.pay.paid", "Paid", "Green, Paid, the order under it.") { app in
            await ApprovalFixtures.payThen(app, .paid)
        },
        NamedState("approval.pay.declined", "Declined", "The card's row red, Payment not completed; Close until the Mac asks again.") { app in
            await ApprovalFixtures.payThen(app, .declined)
        },
        NamedState("approval.pay.retry", "Try again", "Declined, the Mac asked again: another card picked, Try Again.") { app in
            await ApprovalFixtures.payThen(app, .declined)
            ApprovalFixtures.askAgain(app)
            await ApprovalFixtures.wait(0.2)
            ApprovalTray.shared.pickCard("c2")
        },
        NamedState("approval.receipt", "Into its head", "Sent: the tray shrunk into its head, what went under the name, a green tick.") { app in
            await ApprovalFixtures.ask(app, .mail)
            await ApprovalFixtures.wait(0.3)
            ApprovalTray.shared.holdReceipt("Sent \u{00B7} Yab \u{00B7} October update", fold: 1)
        },
    ]

    // MARK: - reading

    private static let reading: [NamedState] = [
        NamedState("approval.mails.window", "A mail open", "The second mail grown into its window: 2 of 3, all its words.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.openWindow(1, key: "tray:row.m2")
        },
        NamedState("approval.mails.next", "The next mail", "Paged sideways to the third.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.openWindow(1, key: "tray:row.m2")
            await ApprovalFixtures.wait(0.7)
            ApprovalTray.shared.windowGoTo(2)
        },
        NamedState("approval.mails.attachment", "An attachment", "The form's page grown full screen out of its thumbnail.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.openWindow(2, key: "tray:row.m3")
            await ApprovalFixtures.wait(0.8)
            if let file = tray.content?.items[safe: 2]?.mail?.files.first { tray.openPicture(file, key: "win:att.m3.\(file.id)") }
        },
        NamedState("approval.mail.window", "Show All", "The one mail's paper grown into its window.") { app in
            await ApprovalFixtures.ask(app, .mail)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.openWindow(0, key: "tray:paper")
        },
        NamedState("approval.archive.all", "11 more", "All 14 as a step, ‹ in the head.") { app in
            await ApprovalFixtures.ask(app, .archive)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.go(.all)
        },
        NamedState("approval.files.picture", "A page full screen", "passport.pdf's first page out of its thumbnail.") { app in
            await ApprovalFixtures.ask(app, .files)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            if let file = tray.content?.files.first { tray.openPicture(file, key: "tray:file.\(file.id)") }
        },
    ]

    // MARK: - held in the middle of a movement

    private static let held: [NamedState] = [
        NamedState("approval.held.rise", "Rising", "The tray a third of the way up, the dim coming with it.") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            ApprovalTray.shared.hold(rise: 180)
        },
        NamedState("approval.held.window", "Growing", "A row 40% of the way into its window, the tray stepping back.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.openWindow(1, key: "tray:row.m2")
            tray.hold(win: 0.4)
        },
        NamedState("approval.held.pull", "Pulled", "The window pulled 100 down, smaller, about to fold.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.openWindow(1, key: "tray:row.m2")
            await ApprovalFixtures.wait(0.8)
            tray.hold(pull: 125)
        },
        NamedState("approval.held.page", "Paging", "Between the second and third mail.") { app in
            await ApprovalFixtures.ask(app, .mails)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.openWindow(1, key: "tray:row.m2")
            await ApprovalFixtures.wait(0.8)
            tray.hold(page: 1.45)
        },
        NamedState("approval.held.step", "Swapping", "Pay With coming over the first body, halfway.") { app in
            await ApprovalFixtures.ask(app, .pay)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            tray.go(.cards)
            tray.hold(swap: 0.5)
        },
        NamedState("approval.held.picture", "Opening a page", "A page halfway out of its thumbnail.") { app in
            await ApprovalFixtures.ask(app, .files)
            await ApprovalFixtures.wait(0.5)
            let tray = ApprovalTray.shared
            if let file = tray.content?.files.first { tray.openPicture(file, key: "tray:file.\(file.id)") }
            tray.hold(picture: 0.5)
        },
        NamedState("approval.held.fold", "Folding", "The tray halfway into its head.") { app in
            await ApprovalFixtures.ask(app, .mail)
            await ApprovalFixtures.wait(0.3)
            ApprovalTray.shared.holdReceipt("Sent \u{00B7} Yab \u{00B7} October update", fold: 0.5)
        },
    ]
}

/// A pretend Mac's questions and their details, as a real Mac sends them.
@MainActor
enum ApprovalFixtures {
    enum Kind { case pay, mails, mail, archive, files, message, signIn, lines, oldMails, search, searchOld }

    static let tab = "0b8f0c3e-5c55-4bd8-8f5e-3cb6f7a1e2d4"

    static func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }

    static func ask(_ app: AppModel, _ kind: Kind, also: Kind? = nil) async {
        var requests: [AssistantApprovalRecords.Request] = []
        var details: [AssistantApprovalRecords.Detail] = []
        var previews: [String: UIImage] = [:]
        for (n, k) in [kind, also].compactMap({ $0 }).enumerated() {
            guard let (request, detail) = make(k, n) else { continue }
            requests.append(request)
            if let detail {
                details.append(detail)
                for file in detail.allFiles {
                    previews[AssistantApprovalRecords.Preview.id(request: request.id, file: file.id, page: 0)] = page(file)
                }
            }
        }
        app.sync.pretendAssistantApprovals(requests, details: details, previews: previews)
        await wait(0.05)
    }

    /// The Mac asks again after a decline: a new question for the same tab.
    static func askAgain(_ app: AppModel) {
        guard let (request, detail) = make(.pay, 7) else { return }
        app.sync.pretendAskAgain(request, detail: detail)
    }

    /// A payment answered yes here, then what the site said, held there.
    static func payThen(_ app: AppModel, _ phase: AssistantApprovalRecords.Result.Phase) async {
        app.sync.pretendPayEnds = nil
        await ask(app, .pay)
        await wait(0.3)
        let tray = ApprovalTray.shared
        tray.hold()
        tray.yes()
        await wait(0.1)
        let id = id(0)
        app.sync.pretendResult(.init(id: id, phase: .paying))
        await wait(0.1)
        switch phase {
        case .paid: app.sync.pretendResult(.init(id: id, phase: .paid, order: "#112-4836027"))
        case .declined: app.sync.pretendResult(.init(id: id, phase: .declined, words: "Payment not completed"))
        default: break
        }
        await wait(0.1)
    }

    static func id(_ n: Int) -> String { String(format: "3f2c6f0e-2b1a-4c55-9a77-0d6c1b1e7a%02d", n) }

    private static func make(_ kind: Kind, _ n: Int) -> (AssistantApprovalRecords.Request, AssistantApprovalRecords.Detail?)? {
        let id = id(n)
        func request(_ permit: String, _ title: String, _ lines: [String], tab: String = Self.tab, choices: [String]? = nil) -> AssistantApprovalRecords.Request? {
            try? AssistantApprovalRecords.Request(id: id, account: "fixture", mac: "mac", assistant: "local.claude", session: "s\(n == 7 ? 0 : n)",
                                                  tab: tab, permit: permit, title: "Claude: \(title)", lines: lines,
                                                  expires: Date().addingTimeInterval(900), choices: choices)
        }
        typealias D = AssistantApprovalRecords.Detail
        switch kind {
        case .pay:
            guard let r = request("press:pay", "Place your order · $42.10?", ["amazon.com", "AirPods Pro ear tips · 2 items", "Amount: $42.10"]) else { return nil }
            return (r, D(id: id, verb: "Pay $42.10", pay: .init(
                site: "amazon.com", item: "AirPods Pro ear tips \u{00B7} 2 items", amount: "$42.10", delivery: "Arrives Thursday, Oct 23 \u{00B7} free",
                cards: [.init(id: "c1", brand: "Visa", last4: "6411", name: "Chase Sapphire"),
                        .init(id: "c2", brand: "American Express", last4: "1005", name: "Sam Rivera"),
                        .init(id: "c3", brand: "Mastercard", last4: "5100", name: "Revolut")],
                places: [.init(id: "p1", line: "14 Grand St, New York", who: "Home"),
                         .init(id: "p2", line: "548 Market St, San Francisco", who: "Office")],
                card: "c1", place: "p1", takesCard: true, takesPlace: true)))
        case .mails:
            guard let r = request("mail.send:3", "Send these 3 mails?", ["mail.google.com", "3 mails"]) else { return nil }
            let me = D.Person(name: "Sam Rivera", address: "sam@mail.example")
            return (r, D(id: id, verb: "Send All 3", mails: [
                .init(id: "m1", from: me, to: [.init(name: "Anna Petrova", address: "anna@studio.co")], subject: "Re: Contract",
                      body: "Hi Anna,\n\nThe signed copy is attached. I initialed each page and signed the last one, as you asked.\n\nTwo small things for next time: the payment schedule in section 4 says net 30, but the invoice template still says net 15. And could the studio send the final files as a single zip?\n\nThanks for the quick turnaround, this was easy.\n\nSam",
                      files: [.init(id: "f1", name: "contract-signed.pdf", bytes: 412_000, kind: "pdf", pages: 3, previews: 1)]),
                .init(id: "m2", from: me, to: [.init(name: "Tom Lee", address: "tom@acme.com")], bcc: [.init(name: "Priya Shah", address: "priya@acme.com")], subject: "Re: Friday",
                      body: "Hi Tom,\n\nFriday at 3pm works. I booked the small room on the 4th floor, the one with the screen.\n\nI'll bring the October numbers and the two designs we talked about. If Priya can join, even better.\n\nSee you then,\nSam"),
                .init(id: "m3", from: me, to: [.init(name: "HR \u{00B7} Northwind", address: "hr@northwind.example")], subject: "Onboarding form",
                      body: "Hi,\n\nThe completed onboarding form is attached, with the bank details on page 2.\n\nMy start date stays November 3. Let me know if anything is missing.\n\nBest,\nSam Rivera",
                      files: [.init(id: "f2", name: "onboarding-form.pdf", bytes: 188_000, kind: "pdf", pages: 2, previews: 1)]),
            ]))
        case .mail:
            guard let r = request("mail.send:1", "Send this mail to Marc Chen?", ["mail.google.com", "To marc@northfund.vc, Subject: Yab · October update"]) else { return nil }
            let body = "Hi Marc,\n\nHere is October in one page, with the details in the attached PDF.\n\nUsers: 4,812 weekly active, up 31% from September. Most of the growth came from people switching from Arc.\n\nRetention: week-4 retention is 46%, up from 39%. The agent chat is the feature people come back for.\n\nRevenue: 212 paying members, $4,240 MRR. We started charging on October 2.\n\nShipping: Mail is out of beta, sync between Macs is live, and the iPhone app is in TestFlight with 300 testers.\n\nNext month: open the iPhone app to everyone, launch on Product Hunt on November 17, and hire a second iOS engineer.\n\nThe one ask: if you know senior iOS engineers who care about motion, I would love an intro.\n\nThanks,\nSam"
            return (r, D(id: id, verb: "Send", mails: [
                .init(id: "m1", from: .init(name: "Sam Rivera", address: "sam@mail.example"),
                      to: [.init(name: "Marc Chen", address: "marc@northfund.vc")], subject: "Yab \u{00B7} October update", body: body,
                      files: [.init(id: "f1", name: "yab-october.pdf", bytes: 1_100_000, kind: "pdf", pages: 6, previews: 1)]),
            ]))
        case .archive:
            guard let r = request("mail.change:archive", "Archive mail in this chat?", ["Inbox cleanup", "once for this chat"], tab: "chat:inbox") else { return nil }
            let senders = [("Dribbble", "This week's top shots"), ("Medium Daily Digest", "Stories for you"), ("Product Hunt", "Top 5 launches today"),
                           ("Substack", "New posts from writers you follow"), ("Figma", "What's new in October"), ("Notion", "Your weekly digest"),
                           ("Y Combinator", "Startup School this week"), ("Linear", "Changelog: project views"), ("Airbnb", "Ideas for your next trip"),
                           ("The Verge", "Daily: the Apple event"), ("Amazon", "Deals picked for you"), ("Raycast", "October update"),
                           ("Spotify", "Your Release Radar"), ("Instagram", "You have 3 new notifications")]
            let now = Date().timeIntervalSince1970
            return (r, D(id: id, verb: "Archive 14", mails: senders.enumerated().map { i, s in
                .init(id: "a\(i)", from: .init(name: s.0, address: "news@\(s.0.lowercased().filter(\.isLetter)).com"),
                      to: [.init(name: "Sam Rivera")], subject: s.1,
                      body: "\(s.1).\n\nA newsletter: nobody wrote to you personally, and nothing in it waits for an answer.\n\nUnsubscribe \u{00B7} View in browser",
                      date: now - Double(i) * 3600 * 5)
            }))
        case .files:
            guard let r = request("upload:2", "Upload 2 files?", ["travel.state.gov", "DS-160 \u{00B7} Step 3 of 5"]) else { return nil }
            return (r, D(id: id, verb: "Upload 2 Files", files: [
                .init(id: "f1", name: "passport.pdf", bytes: 1_400_000, kind: "pdf", pages: 2, previews: 1),
                .init(id: "f2", name: "photo.jpg", bytes: 210_000, kind: "image", width: 600, height: 600, previews: 1),
            ]))
        case .message:
            guard let r = request("message:mom", "Send to Mom?", ["mail.google.com", "Running 10 minutes late, start without me"]) else { return nil }
            return (r, D(id: id, verb: "Send", text: "Running 10 minutes late, start without me", person: .init(name: "Mom")))
        case .signIn:
            guard let r = request("signin:github.com", "Sign in to github.com?", ["github.com"], choices: ["samrivera", "sam-work", "yab-test"]) else { return nil }
            return (r, nil)
        case .search, .searchOld:
            guard let r = request("mail.read", "Search your mail?", ["Reply to testers", "once for this chat"], tab: "chat:" + Self.tab) else { return nil }
            if kind == .searchOld { return (r, nil) }
            return (r, D(id: id, verb: "Allow in This Chat",
                         text: "Looks for \u{201C}Yab 0.32 newer_than:7d\u{201D}\nClaude reads what it finds on your plan, under Anthropic\u{2019}s terms. Yab keeps no copy."))
        case .oldMails:
            // As Yab 0.34.2 asks from the tab its agent is on: the lines only.
            let draft = "1. To dana.kim@example.com · Re: Yab 0.32\nHey Dana, Yab 0.34.4 is out: each mail account now has a \"Show in All Accounts\" switch in Settings › Mail.\n\n"
                + "2. To ivo.lane@example.com · Re: Yab 0.33.3\nHey Ivo, in 0.34.3 Auto no longer picks a model you don't have, and Cursor's models show up in every list.\n\n"
                + "3. To hugo.kern@example.com · Re: Yab 0.33.3\nHey Hugo, the gray space left after closing DevTools is gone.\n\n"
                + "4. To greta.hall@example.com · Re: Yab 0.34\nHey Greta, the crash on opening a second window is fixed in 0.34.4."
            guard let r = request("mail.send:4", "Send these 4 mails?",
                                  ["x.com", "To Dana Kim; ivo.lane@example.com; hugo.kern@example.com; greta.hall@example.com", draft]) else { return nil }
            return (r, nil)
        case .lines:
            guard let r = request("press:post", "Post?", ["x.com", "Reply to @arcinternet: same here, the new sidebar is great"]) else { return nil }
            return (r, nil)
        }
    }

    /// A page as a Mac's preview would picture it: a document's lines, or a portrait.
    static func page(_ file: AssistantApprovalRecords.Detail.File) -> UIImage {
        let size = file.kind == "image" ? CGSize(width: 600, height: 600) : CGSize(width: 612, height: 792)
        return UIGraphicsImageRenderer(size: size).image { context in
            let c = context.cgContext
            if file.kind == "image" {
                UIColor(red: 0.79, green: 0.72, blue: 0.64, alpha: 1).setFill(); c.fill(CGRect(origin: .zero, size: size))
                UIColor(red: 0.49, green: 0.39, blue: 0.32, alpha: 1).setFill(); c.fillEllipse(in: CGRect(x: 180, y: 120, width: 240, height: 210))
                UIColor(red: 0.24, green: 0.29, blue: 0.39, alpha: 1).setFill(); c.fillEllipse(in: CGRect(x: 100, y: 350, width: 400, height: 400))
            } else {
                UIColor.white.setFill(); c.fill(CGRect(origin: .zero, size: size))
                UIColor(white: 0.55, alpha: 1).setFill(); c.fill(CGRect(x: 60, y: 70, width: 300, height: 18))
                UIColor(white: 0.84, alpha: 1).setFill()
                for i in 0..<26 {
                    let w: CGFloat = i % 5 == 4 ? 240 : 492
                    c.fill(CGRect(x: 60, y: 120 + CGFloat(i) * 24, width: w, height: 8))
                }
            }
        }
    }
}
