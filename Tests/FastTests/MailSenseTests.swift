import Foundation
import Testing
@testable import Fast
@testable import MailCore

// What a thread wants, by the rules alone (docs/mail.md, Sense), and the
// rows it makes on the new tab (Daily).
struct MailSenseTests {
    // Monday, Sep 28 2026, 10:00 local.
    static let now: Date = {
        var parts = DateComponents(year: 2026, month: 9, day: 28, hour: 10)
        parts.calendar = Calendar.current
        return parts.date!
    }()

    func message(_ from: String, _ subject: String, _ text: String, ago: TimeInterval = 3600, bulk: Bool = false) -> MailMessage {
        MailMessage(id: UUID().uuidString, thread: "t", from: MailPerson.one(from)!, subject: subject, snippet: text,
                    date: Self.now.addingTimeInterval(-ago), labels: ["INBOX"], listUnsubscribe: bulk, text: text)
    }

    @Test func kindsByTheirWords() {
        #expect(MailSense.kind(message("Linear <no-reply@linear.app>", "Your login code", "Your code is 481902"), bulk: false) == .code)
        #expect(MailSense.kind(message("Ledgerly <billing@ledgerly.io>", "Invoice #4471 is past due", "Your card was declined"), bulk: false) == .invoice)
        #expect(MailSense.kind(message("Shop <orders@shop.example>", "Your order has shipped", "Tracking number 1Z"), bulk: false) == .shipping)
        #expect(MailSense.kind(message("Digest <news@digest.io>", "Ten links", "Read on"), bulk: true) == .list)
        #expect(MailSense.kind(message("Anna Lindqvist <anna@fold.studio>", "Thursday works?", "Can we do Thursday?"), bulk: false) == .person)
    }

    @Test func robotsByTheirAddress() {
        let robot = { (from: String, subject: String) in
            MailSense.kind(self.message(from, subject, "Questions? Reply to this email."), bulk: false)
        }
        // No person writes from these, in a conversation or not.
        for from in ["X <verify@x.com>", "Slack <notification@slack-mail.com>", "Brex <payment_alerts@brex.com>",
                     "Chase <no.reply.alerts@chase.com>", "Apple <testflight_no_reply@email.apple.com>",
                     "Hawaiian <transactions@email.hawaiianairlines.com>", "Chase Fraud Alert <chase@fraudalert.chase.com>",
                     "AWS <budgets@costalerts.amazonaws.com>"] {
            #expect(robot(from, "Heads up") == .list, "\(from)")
        }
        // Shared boxes and a domain's mail-sending part, outside a conversation.
        for from in ["Paddle <help@paddle.com>", "Zoom <billing@zoom.us>", "Central <app@mail.central.inc>",
                     "Stripe <support+lpm-adoption@stripe.com>", "Instacart <orders@instacart.com>",
                     "Charlotte <charlotte@mail.octolens.com>"] {
            #expect(robot(from, "An update on your account") == .list, "\(from)")
        }
        // A business answering you from a shared box is a person: you wrote,
        // or it replies to what you sent from elsewhere.
        let clinic = message("Orthoworks <info@orthoworks.com>", "Retainer cost", "It is $450. Would Tuesday work?")
        #expect(MailSense.kind(clinic, bulk: false, conversation: true) == .person)
        #expect(robot("Resend <support@resend.com>", "Re: Request for W-9 Form") == .person)
        // Google's reviewers write from a "verification" address; a
        // university's mail part is people's; a customer's address is theirs.
        #expect(robot("Google <api-oauth-dev-verification-reply+2b7e@google.com>", "[Action Needed] OAuth Verification") == .person)
        #expect(robot("Mia <mia.chen@mail.utoronto.edu>", "Internship") == .person)
        #expect(robot("Tony <tony.siress@gmail.com>", "I keep getting charged") == .person)
        #expect(robot("Rocket <accounts@rocket.new>", "Request for W-9 Form") == .person)
    }

    @Test func aDateItNamesForSomethingToBeDone() {
        // A fixed zone and day, whatever today and this Mac's zone are.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        func day(_ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
        }
        let monday = day(9, 28, 10)
        let friday = day(10, 2)
        for words in ["Could you send September MAU and revenue by Friday?", "Please hold the room until Friday.",
                      "Need the deck EOD Friday."] {
            #expect(MailSense.due(in: words, now: monday, calendar: calendar) == friday, "\(words)")
        }
        // From the mail's own day, not the day it is read: Wednesday's
        // "by Friday" read on Thursday, and two weeks on, that week's Friday.
        let numbers = "Please send the numbers by Friday."
        #expect(MailSense.due(in: numbers, now: day(10, 1, 9), sent: day(9, 30, 15), calendar: calendar) == friday)
        #expect(MailSense.due(in: numbers, now: day(10, 12, 10), calendar: calendar) == day(10, 16))
        // The Friday of a mail from the week before is over.
        #expect(MailSense.due(in: numbers, now: monday, sent: day(9, 22, 10), calendar: calendar) == nil)
        // A date said in passing isn't a deadline.
        #expect(MailSense.due(in: "We met on Friday and it went well.", now: monday, calendar: calendar) == nil)
    }

    @Test func whetherSomeoneAsks() {
        #expect(MailSense.asks("Can we do the review this week"))
        #expect(MailSense.asks("Who else joins?"))
        #expect(!MailSense.asks("Release 0.0.1 build passed."))
    }

    @Test func theRulesReadingOfAThread() {
        let mail = message("Mark Chen <mark@northwind.vc>", "Quick update", "Could you send September MAU and revenue by Friday?")
        let thread = MailThread(id: "t", subject: "Quick update", snippet: "", last: mail.date, labels: ["INBOX"], unread: true,
                                people: [mail.from], count: 1, lastIsMine: false)
        let sensed = MailSense.rules(thread, messages: [mail], me: "me@example.com", now: Self.now)
        #expect(sensed?.needs == true)
        #expect(sensed?.kind == .person)
        #expect(sensed?.due == Calendar.current.date(byAdding: .day, value: 4, to: Calendar.current.startOfDay(for: Self.now)))
        #expect(sensed?.gist.hasPrefix("Could you send") == true)
    }

    @Test func coldSalesFollowUpDoesNotBecomeAnAction() {
        let sender = "Sam <sam@studio.example>"
        let pitch = "We run a film studio doing launch distribution for SaaS. If its useful I'll send a short Loom."
        let first = message(sender, "Your next launch", pitch, ago: 8 * 86_400)
        let followUp = message(sender, "Re: Your next launch", "Bringing this back up in case it slipped past.\n\n" + pitch, ago: 2 * 86_400)
        let thread = MailThread(id: "t", subject: "Your next launch", snippet: "", last: followUp.date,
                                labels: ["INBOX", "IMPORTANT", "CATEGORY_PERSONAL"], unread: true,
                                people: [followUp.from], count: 2, lastIsMine: false)
        let sensed = MailSense.rules(thread, messages: [first, followUp], me: "me@example.com", now: Self.now)!
        #expect(sensed.kind == .promotion)
        #expect(!sensed.needs)
        #expect(MailSplit.of(thread, sensed: sensed, now: Self.now) == .other)

        // Even a model that calls the follow-up a request cannot put it in Now.
        let stale = MailSensed(thread: "t", message: followUp.id, needs: false, gist: "", due: nil, kind: .person)
        let refined = MailSense.refined(stale, gist: "Wants a reply", needs: true, promotion: true, cold: true)
        #expect(refined.kind == .promotion)
        #expect(!refined.needs)
        #expect(MailSplit.of(thread, sensed: refined, now: Self.now) == .other)
    }

    @Test func existingFalsePositiveIsReclassified() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-sense-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        store.set("me", "me@example.com")
        store.set("sense-version", "7:rules")
        let pitch = "We run a film studio doing launch distribution. If its useful I'll send a short Loom."
        let mail = message("Sam <sam@studio.example>", "Re: Your next launch", "Bringing this back up.\n\n" + pitch, ago: 9 * 86_400)
        store.put([mail])
        store.keep(MailSensed(thread: "t", message: mail.id, needs: true, gist: "Wants a reply", due: nil,
                              kind: .person, byModel: true))

        await MailSense.run(store, now: Self.now, model: false, changed: {})

        #expect(store.sensed("t")?.kind == .promotion)
        #expect(store.sensed("t")?.needs == false)
        #expect(store.value("sense-version") == "8:rules")
    }

    func thread(_ mail: MailMessage) -> MailThread {
        MailThread(id: mail.thread, subject: mail.subject, snippet: "", last: mail.date, labels: ["INBOX", "IMPORTANT"], unread: true,
                   people: [mail.from], count: 1, lastIsMine: false)
    }

    @Test func aSequencesLineToStopItsMailMakesItAPitch() {
        let body = "Hi,\n\nOur team covers bookkeeping and reporting for growing companies.\n"
            + "Would the beginning or end of next week work better for a brief introduction?\n\nBest,\nKip\n\n"
        // Without the line it reads as a person's question.
        #expect(!MailSense.salesPitch("More visibility\n" + body))
        // However a sequence words it, under every mail it sends.
        for line in ["Feel free to inform us if you\u{2019}d like to stop receiving emails",
                     "Let us know if you no longer wish to receive updates, and we\u{2019}ll make sure you\u{2019}re not on the list",
                     "Not your cup of tea? Just reply, and we\u{2019}ll take care of it.",
                     "Notify us if you no longer wish to hear from us, and we will remove you from future messages",
                     "If you'd like me to stop sending you emails, please click here",
                     "If this is not for you, let us know and we\u{2019}ll stop all future emails",
                     "Not interested? Just reply \u{201C}no thanks\u{201D}"] {
            #expect(MailSense.salesPitch("More visibility\n" + body + line), "\(line)")
        }
        let mail = message("Kip Lane <kip@e.trykipcapacity.example>", "More visibility without more headcount",
                           body + "Feel free to inform us if you\u{2019}d like to stop receiving emails", ago: 3 * 86_400)
        let sensed = MailSense.rules(thread(mail), messages: [mail], me: "me@example.com", now: Self.now)!
        #expect(sensed.kind == .promotion)
        #expect(!sensed.needs)
        #expect(MailSplit.of(thread(mail), sensed: sensed, now: Self.now) == .other)
    }

    @Test func aSalesTitleHuntingTheRightPersonIsAPitch() {
        let ask = "Hi,\n\nAre you the right person to discuss ads with at Acme? If not, who would\nbe?\n\nThanks,\nNia\n"
        #expect(MailSense.salesPitch("Checking for best contact\n" + ask + "Nia Clark\nClient Partner"))
        // A stranger looking for the right person, selling nothing, is not.
        #expect(!MailSense.salesPitch("Security issue\nAre you the right person to talk to about a security issue in your API? If not, who would be?"))
    }

    @Test func aPitchTheRulesTookForAMeeting() {
        // "Meetings on the calendar" made it a meeting by its words alone.
        let pitch = message("Kip Lane <kip@e.trykipcapacity.example>", "Extra finance capacity",
                            "We\u{2019}ve helped companies get fundraise-ready, with investor meetings on the calendar within weeks.\n"
                            + "Worth a 15-minute call?\n\nKip Lane\nBusiness Development Specialist\n\n"
                            + "Let us know if you no longer wish to receive updates")
        #expect(MailSense.kind(pitch, bulk: false) == .meeting)
        #expect(MailSense.rules(thread(pitch), messages: [pitch], me: "me@example.com", now: Self.now)?.kind == .promotion)
        // An invitation's footer says how to stop its updates: still an invitation.
        let invite = message("Aaron <aaron@accelerator.example>", "Invitation: Office hours @ Thu 1 Oct 2026 2:30pm",
                             "Office hours\nThursday 1 Oct 2026\n\nInvitation from Google Calendar\n"
                             + "If you'd like to stop receiving updates for this event, decline this event.")
        #expect(MailSense.rules(thread(invite), messages: [invite], me: "me@example.com", now: Self.now)?.kind == .meeting)
    }

    @Test func whatIsNotAPitch() {
        let me = "me@example.com"
        // A customer who wants out is a person waiting on you.
        let customer = message("Dora <dora@mail.example>", "Cancel", "Hi, I want to unsubscribe from your service and stop receiving emails. How do I do it?")
        let sensed = MailSense.rules(thread(customer), messages: [customer], me: me, now: Self.now)!
        #expect(sensed.kind == .person)
        #expect(sensed.needs)
        // Your team's mail, and a pitch passed on to you, are people's.
        let line = "\n\nIf you'd like me to stop sending you these, just say so. Can you look today?"
        let team = message("Lee <lee@example.com>", "Weekly numbers", "The numbers are in." + line)
        #expect(MailSense.rules(thread(team), messages: [team], me: me, now: Self.now)?.kind == .person)
        let passed = message("Ann <ann@fold.studio>", "Fwd: Extra capacity", "Worth a look?\n\n---------- Forwarded message ----------" + line)
        #expect(MailSense.rules(thread(passed), messages: [passed], me: me, now: Self.now)?.kind == .person)
        // On a common domain everyone writes from, the same domain isn't a team.
        let pitch = message("Kip <kip.lane@gmail.com>", "Capacity", "Our team covers bookkeeping." + line)
        #expect(MailSense.rules(thread(pitch), messages: [pitch], me: "me@gmail.com", now: Self.now)?.kind == .promotion)
    }

    /// What a test's stand-in for the model was given.
    actor Given {
        var ids: [String] = []
        func add(_ id: String) { ids.append(id) }
    }

    func freshStore() -> (MailStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-sense-" + UUID().uuidString)
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        store.set("me", "me@example.com")
        store.set("sense-version", "8:model")
        return (store, folder)
    }

    @Test func theModelReadsWhatTheRulesAloneLeft() async {
        let (store, folder) = freshStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mail = message("Dana <dana@gosync.example>", "more meetings?", "Are you trying to book more meetings with engineering leads?", ago: 2 * 86_400)
        store.put([mail])
        // Kept by the rules in a run the model never got to.
        store.keep(MailSensed(thread: "t", message: mail.id, needs: true, gist: "", due: nil, kind: .person))
        let given = Given()
        await MailSense.run(store, now: Self.now, model: true, reader: { message, _ in
            await given.add(message.id)
            return (gist: "Wants to book more meetings", needs: true, promotion: true)
        }, changed: {})
        #expect(await given.ids == [mail.id])
        #expect(store.sensed("t")?.kind == .promotion)
        #expect(store.sensed("t")?.byModel == true)
    }

    @Test func mailTheModelCouldNotReadIsGivenOnceALaunch() async {
        let (store, folder) = freshStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mail = message("Dana <dana@gosync.example>", "more meetings?", "Are you trying to book more meetings?", ago: 2 * 86_400)
        store.put([mail])
        store.keep(MailSensed(thread: "t", message: mail.id, needs: true, gist: "", due: nil, kind: .person))
        let given = Given()
        for _ in 0..<2 {
            await MailSense.run(store, now: Self.now, model: true, reader: { message, _ in
                await given.add(message.id)
                return nil
            }, changed: {})
        }
        #expect(await given.ids == [mail.id])
        #expect(store.sensed("t")?.byModel == false)
    }

    @Test func anApplicantIsNotAPitch() async {
        let (store, folder) = freshStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let mail = message("Sasha <sasha.dev@gmail.com>", "Can I join your team as a senior developer?",
                           "Hi, I build React apps and would love to help. Are you hiring?", ago: 2 * 86_400)
        store.put([mail])
        // The Mac's model calls an applicant's offer of themselves a pitch.
        await MailSense.run(store, now: Self.now, model: true, reader: { _, _ in
            (gist: "Wants to join the team", needs: true, promotion: true)
        }, changed: {})
        #expect(store.sensed("t")?.kind == .person)
        #expect(store.sensed("t")?.needs == true)
    }

    // The model reads a mail with the user's own last word before it, and
    // its no stands: a bank's "Did you use your card?" asks for a button.
    @Test func theModelReadsTheThreadAndItsNoStands() {
        let mine = message("Me <me@example.com>", "Re: Fixed in Yab", "Shortcuts sync is coming in the next update.", ago: 86_400)
        let theirs = message("Danny <danny@example.com>", "Re: Fixed in Yab", "NordPass works now! Autofill still says locked.", ago: 3600)
        let before = MailSense.before(theirs, in: [mine, theirs], me: "me@example.com")
        #expect(before == "Shortcuts sync is coming in the next update.")
        #expect(MailSense.before(mine, in: [mine, theirs], me: "me@example.com") == nil)
        let prompt = MailSense.prompt(for: theirs, before: before)
        #expect(prompt.contains("[The user's own last email in this thread, before this one]"))
        #expect(prompt.contains("Shortcuts sync is coming"))
        #expect(MailSense.instructions.contains("answered with a button"))

        let alert = MailSensed(thread: "t", message: "c", needs: true, gist: "", kind: .person)
        #expect(!MailSense.refined(alert, gist: "Asks to confirm a card payment", needs: false, promotion: false, cold: true).needs)
        let bill = MailSensed(thread: "t", message: "b", needs: true, gist: "", kind: .invoice)
        #expect(MailSense.refined(bill, gist: "Says the card was declined", needs: false, promotion: false, cold: true).needs)
    }

    func thread(_ messages: [MailMessage], me: String = "me@example.com") -> MailThread {
        MailThread(id: "t", subject: messages[0].subject, snippet: "", last: messages.last!.date, labels: ["INBOX"], unread: true,
                   people: [messages.last!.from], count: messages.count, lastIsMine: messages.last!.from.address == me)
    }

    // A Needs you list checked mail by mail (2026-10-14): what wrongly sat
    // there, and what rightly stays.
    @Test func whatWaitsOnNoOne() {
        let me = "me@example.com"
        // "Thanks man" under your answer about a Stripe invoice: a person's
        // thanks, not an invoice, and nothing open.
        let mine = message("Me <me@example.com>", "Re: Bitwarden in Yab",
                           "Stripe invoice download is fixed in 0.0.23. Yab stays on WebKit.", ago: 2 * 3600)
        let thanks = message("Casey <casey@example.com>", "Re: Bitwarden in Yab",
                             "Thanks man\n\nOn Wed, 14 Oct 2026 at 6:35 AM <me@example.com> wrote:\n> Stripe invoice download is fixed in 0.0.23.")
        let closed = MailSense.rules(thread([mine, thanks]), messages: [mine, thanks], me: me, now: Self.now)!
        #expect(closed.kind == .person)
        #expect(!closed.needs)
        #expect(MailSense.settles("Thanks man"))
        #expect(MailSense.settles("Ok, got it"))
        #expect(MailSense.settles("Hi, I'm reviewing the case on my side. I'll keep you informed."))
        #expect(!MailSense.settles("Thanks! Can you also check the export?"))
        #expect(!MailSense.settles("Thanks. Also the export is broken"))
        #expect(MailSense.settles("Sickkk, and okay gotcha. I think that would be a nice option but ultimately I respect your discernment! Thanks for the update."))
        #expect(MailSense.settles("If everything looks good, a quick rating on the survey would mean a lot. Take care!"))
        // A customer's ask with no question mark still waits on you.
        #expect(!MailSense.settles("Following up on this. There's no need to reissue the invoice: your EIN (or a W-9) is all my accountant needs. Thanks, Joel"))

        // An auto-reply is told, not waiting on you.
        let auto = message("Abuse Team <abuse@registrar.example>", "Auto-Reply: Abuse report",
                           "If our webform fails, please reply with screenshots.")
        #expect(MailSense.kind(auto, bulk: false) == .other)
    }

    @Test func aStrangersSequenceAskingForACallIsAPitch() {
        let me = "me@example.com"
        let pitch = { (messages: [MailMessage]) in MailSense.rules(self.thread(messages), messages: messages, me: me, now: Self.now)! }
        // Unanswered follow-ups: "Worth a quick chat?", "let's talk tomorrow or Monday".
        let broker = [message("Sam <sam@benefits.example>", "benefits renewal", "Is it worth 20 min if you're open to switching brokers?", ago: 5 * 86_400),
                      message("Sam <sam@benefits.example>", "Re: benefits renewal", "One of the GMs we work with said it well. Worth a quick chat?")]
        #expect(pitch(broker).kind == .promotion)
        let loans = [message("Hana <hana@capital.example>", "loc for you", "I'm helping businesses get capital - let's talk tomorrow or Monday?", ago: 6 * 86_400),
                     message("Hana <hana@capital.example>", "Re: loc for you", "Is it alright if I share the numbers and terms we could offer you?")]
        #expect(pitch(loans).kind == .promotion)
        // "Let me know if not of interest and I will not follow up further."
        let data = [message("Hugo <hugo@vouch.example>", "You + Hugo", "Worth a 15-minute conversation? Let me know if not of interest and I will not follow up further.")]
        #expect(pitch(data).kind == .promotion)
        // A seller's "would you want to hear more?", in one mail.
        let leads = [message("Sophie <sophie@leads.example>", "Sam?", "If we could introduce you to software developers at tech companies, would you want to hear more?")]
        #expect(pitch(leads).kind == .promotion)
        let films = [message("Will <will@films.example>", "Films × you",
                             "We’re the creative team behind many of the product launch films at the top of your feed. We’d love to chat, share some work, or brainstorm ideas.")]
        #expect(pitch(films).kind == .promotion)

        // A fund's follow-up and an applicant's are people's.
        let fund = [message("Sami <sami@fund.example>", "Intro", "We're a leading early-stage VC backing companies from pre-seed. Open to a quick 20-min intro call?", ago: 5 * 86_400),
                    message("Sami <sami@fund.example>", "Re: Intro", "Following up. Would you have time for a quick 30-minute call?")]
        #expect(pitch(fund).kind == .person)
        let student = [message("Paul <paul@example.com>", "Carleton new grad, and a question",
                               "Would you be open to a 15 minute call? I'd like to hear how you think about early career engineers. Not the right inbox? Reply and I will not follow up.")]
        #expect(pitch(student).kind == .person)
        #expect(pitch(student).needs)
        // You wrote in it: an answer, not a pitch.
        let mine = message("Me <me@example.com>", "benefits renewal", "Send me the options.", ago: 6 * 86_400)
        #expect(pitch([mine] + broker).kind == .person)
    }

    @Test func theLineOfAMailThatAsksIsItsQuestion() {
        let clinic = message("Clinic <tc@clinic.example>", "Re: retainer cost",
                             "Hi good morning, Sam. I apologize for our delayed response. Dr. Chen would like to meet you for a free consultation. Would you like to schedule a consultation?\n\nBest,\nMeghan")
        let sensed = MailSense.rules(thread([clinic]), messages: [clinic], me: "me@example.com", now: Self.now)!
        #expect(sensed.needs)
        #expect(sensed.gist == "Would you like to schedule a consultation?")
        #expect(MailSense.tidy("wants to know about remaining bugs.") == "Wants to know about remaining bugs")
        // A bare second try at a line takes the sender's words alone.
        let mine = message("Me <me@example.com>", "Re: Fixed in Yab", "If it still happens on 0.0.23, a screen recording would help.", ago: 86_400)
        let theirs = message("Danny <danny@example.com>", "Re: Fixed in Yab",
                             "NordPass is fixed! Autofill still says locked.\n\nOn Tue, Oct 13, 2026, 9:05 PM <me@example.com> wrote:\n> If it still happens on 0.0.23, a screen recording would help.")
        let bare = MailSense.prompt(for: theirs, before: MailSense.before(theirs, in: [mine, theirs], me: "me@example.com"), bare: true)
        #expect(!bare.contains("screen recording"))
        #expect(bare.contains("Autofill still says locked"))
        #expect(MailSense.instructions.contains("your line says the answer itself"))
    }

    @Test func anExistingConversationCanStillNeedAReply() {
        let offer = message("Sam <sam@studio.example>", "Launch plan", "We run a studio. If its useful I'll send a plan.")
        let mine = message("Me <me@example.com>", "Re: Launch plan", "Please send the plan.", ago: 2 * 3600)
        let thread = MailThread(id: "t", subject: "Launch plan", snippet: "", last: offer.date,
                                labels: ["INBOX"], unread: true, people: [offer.from], count: 2, lastIsMine: false)
        let sensed = MailSense.rules(thread, messages: [mine, offer], me: "me@example.com", now: Self.now)!
        #expect(sensed.kind == .person)
        let refined = MailSense.refined(sensed, gist: "Asks for feedback", needs: true, promotion: true, cold: false)
        #expect(refined.kind == .person)
        #expect(refined.needs)
        #expect(MailSplit.of(thread, sensed: refined, now: Self.now) == .needs)
    }

    // MARK: - a mail's own words

    @Test func previewsLeaveOutWhatAMailQuotes() {
        // Gmail's snippet of a reply: its header said in full, cut short by the snippet's end, and as Yab writes it.
        let loft = "The loft, please. I'll book it today."
        #expect(MailSense.unquoted(loft + " On Thu, Oct 1, 2026 at 2:00\u{202F}PM Anna Lindqvist <anna@fold.studio> wrote: > Which one?") == loft)
        #expect(MailSense.unquoted(loft + " On Thu, Oct 1, 2026 at 2:") == loft)
        #expect(MailSense.unquoted(loft + " On Thu, Oct 1, 2026 at 2:00 PM, Anna Lindqvist <anna@fold.studio> wrote: > Which") == loft)
        #expect(MailSense.unquoted(loft + " On Thu, 1 Oct 2026 at 14:00, Anna Lindqvist <anna@fold.s") == loft)
        // Apple Mail's and Thunderbird's.
        #expect(MailSense.unquoted("Sure. On Oct 1, 2026, at 14:00, Anna <anna@fold.studio> wrote: > Lunch?") == "Sure.")
        #expect(MailSense.unquoted("Sure. On Oct 1, 2026, at 14:") == "Sure.")
        #expect(MailSense.unquoted("Sure. On 01/10/2026 14:00, Anna wrote: > Lunch?") == "Sure.")
        // A numeric date and time, then the sender, with no verb.
        #expect(MailSense.unquoted("Yes, the loft. 01.10.2026, 14:00, \"Anna\" <anna@fold.studio>: > Which?") == "Yes, the loft.")
        // German and French as Gmail writes them; Outlook's head.
        #expect(MailSense.unquoted("Ja. Am Do., 1. Okt. 2026 um 14:00 Uhr schrieb Anna <anna@fold.studio>: > Welche?") == "Ja.")
        #expect(MailSense.unquoted("Oui. Le jeu. 1 oct. 2026 à 14:00, Anna <anna@fold.studio> a écrit : > Lequel ?") == "Oui.")
        #expect(MailSense.unquoted("Done. From: Anna Lindqvist <anna@fold.studio> Sent: Thursday, October 1, 2026 2:00 PM To: Me") == "Done.")
        // Words that only look like it stay as they are.
        for plain in ["On Monday we ship the update, and on Oct 5 the docs follow.", "We met on Thu, Oct 1, 2026 at the office."] {
            #expect(MailSense.unquoted(plain) == plain)
        }

        // Its words, once they are here: above the quote, or under the lines it quotes.
        func mail(_ text: String) -> MailMessage { message("Anna Lindqvist <anna@fold.studio>", "Re: Rooms", text) }
        #expect(MailSense.preview(mail("The loft, please.\n\nOn Thu, Oct 1, 2026 at 2:00 PM Anna <anna@fold.studio> wrote:\n> Which one?"))
                == "The loft, please.")
        #expect(MailSense.preview(mail("Yes, the loft.\n\n01.10.2026, 14:00, Anna Lindqvist <anna@fold.studio>:\n\n> Which one?"))
                == "Yes, the loft.")
        // A header run onto a second line at the address.
        #expect(MailSense.preview(mail("Yes.\n\n01.10.2026, 14:00, Anna Lindqvist <\nanna@fold.studio>:\n> Which?")) == "Yes.")
        #expect(MailSense.preview(mail("On Thu, Oct 1, 2026 at 2:00 PM Anna <anna@fold.studio> wrote:\n> Which one?\n\nThe loft.")) == "The loft.")
        // Only the quote, nothing of its own: nothing to say, rather than the header.
        #expect(MailSense.preview(mail("On Thu, Oct 1, 2026 at 2:00 PM Anna <anna@fold.studio> wrote:\n> Which one?")) == "")
    }

    @Test func aRowAndANotificationSayTheMailsOwnWords() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-own-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        store.set("me", "me@example.com")
        let me = MailPerson(name: "Me", address: "me@example.com"), anna = MailPerson.one("Anna Lindqvist <anna@fold.studio>")!
        let asked = MailMessage(id: "r1", thread: "rooms", from: anna, to: [me], subject: "Rooms", snippet: "Which one, the loft or the studio?",
                                date: Self.now.addingTimeInterval(-3 * 3600), labels: ["INBOX"], text: "Which one, the loft or the studio?")
        // Your reply, the last mail, as Gmail's snippet has it: the row says its own words.
        let mine = MailMessage(id: "r2", thread: "rooms", from: me, to: [anna], subject: "Re: Rooms",
                               snippet: "The loft, please. I'll book it today. On Thu, Oct 1, 2026 at 2:00 PM Anna Lindqvist <anna@fold.studio> wrote: > Which one",
                               date: Self.now.addingTimeInterval(-2 * 3600), labels: ["INBOX", "SENT"])
        store.put([asked, mine])
        #expect(store.thread("rooms")?.snippet == "The loft, please. I'll book it today.")
        // Her answer quoting your question: its line is hers, and she asks nothing.
        let text = "Booked, see you there.\n\nOn Thu, Oct 1, 2026 at 2:05 PM Me <me@example.com> wrote:\n> Could you book the loft by Friday?"
        store.put([MailMessage(id: "r3", thread: "rooms", from: anna, to: [me], subject: "Re: Rooms", snippet: MailSense.line(text),
                               date: Self.now.addingTimeInterval(-60), labels: ["INBOX", "UNREAD"], text: text)])
        await MailSense.run(store, now: Self.now, model: false) {}
        let sensed = store.sensed("rooms")
        #expect(sensed?.gist == "Booked, see you there.")
        #expect(sensed?.needs == false)
        #expect(sensed?.due == nil)
        #expect(store.thread("rooms")?.snippet == "Booked, see you there.")
        // Asking nothing, it needs you no longer (docs/mail.md, Only what matters);
        // Everything in Inbox says it, in her own words.
        #expect(MailNotify.fresh(in: store, mode: .needs, since: Self.now.addingTimeInterval(-600), now: Self.now).isEmpty)
        let said = MailNotify.fresh(in: store, mode: .inbox, since: Self.now.addingTimeInterval(-600), now: Self.now)
        #expect(said.map(\.line) == ["Booked, see you there."])
    }

    // MARK: - the Mac's model

    /// Words of the examples the model was once shown, which came back as
    /// gists of mail that never said them.
    static let examples = ["MAU", "revenue", "design review", "slot", "declined", "1,240", "September", "Friday"]

    @Test func theModelIsShownNoLineToCopy() {
        let told = MailSense.instructions
        // No example of a line: no number, no day or month, nothing quoted, none of the old examples' words.
        #expect(told.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(!told.contains("\""))
        for word in Self.examples + ["Monday", "Tuesday", "Wednesday", "Thursday", "Saturday", "Sunday", "January", "October"] {
            #expect(!told.localizedCaseInsensitiveContains(word), "the instructions say \(word)")
        }
        // A mail unlike the examples: its own words in the fence, the quote apart and short, nothing else of anyone's.
        let lease = message("Olga Petrova <olga@petrova.realty>", "Lease renewal",
                            "Good afternoon! We are renewing the apartment lease on Garden Street: 2,150 euros a month from November 1. Please sign the lease by Wednesday.\n\n"
                            + "On Thu, Oct 1, 2026 at 2:00 PM Me <me@example.com> wrote:\n> What are the terms for next year?")
        let prompt = MailSense.prompt(for: lease)
        #expect(prompt.contains("Please sign the lease by Wednesday."))
        #expect(prompt.contains("[Quoted from an earlier email, not the sender's words now]\nOn Thu, Oct 1, 2026 at 2:00 PM Me <me@example.com> wrote:\nWhat are the terms for next year?"))
        #expect(prompt.hasPrefix("From: Olga Petrova\nSubject: Lease renewal\n\n<email>\n"))
        #expect(prompt.hasSuffix("\n</email>"))
        for word in Self.examples { #expect(!prompt.contains(word)) }

        // A line keeps only the mail's own numbers and days.
        let mail = lease.subject + "\n" + (lease.text ?? "")
        #expect(MailSense.grounded("Asks to sign the lease renewal by Wednesday, 2,150 euros a month", in: mail))
        #expect(!MailSense.grounded("Wants September MAU and revenue by Friday", in: mail))
        #expect(!MailSense.grounded("Asks to sign by Wednesday, 2,500 euros a month", in: mail))
        #expect(MailSense.grounded("Says the card was declined, $1,240.00 due", in: "Your card was declined. $1240 is due."))
        #expect(!MailSense.grounded("Wants the numbers by Friday", in: "Could you send the numbers by Tuesday?"))
    }

    /// The Mac's own model on a mail unlike anything it was ever shown:
    /// where it is (Apple Intelligence on), its line says only what the
    /// mail does; where it isn't, what it would be told is checked instead.
    @Test func theMacsModelReadsAMailUnlikeTheExamples() async {
        let mail = message("Dr. Ilse Brandt <praxis@brandt-zahn.de>", "Your appointment",
                           "Hello, your dental check-up moved to Wednesday, 7 October at 8:30. Please confirm by replying to this email.")
        guard MailSense.ready else {
            let prompt = MailSense.prompt(for: mail)
            #expect(prompt.contains("dental check-up moved to Wednesday, 7 October at 8:30"))
            #expect(!MailSense.instructions.contains("Wants September"))
            return
        }
        guard let read = await MailSense.Reader().read(mail) else { return }
        let gist = read.gist
        #expect(gist.isEmpty || MailSense.grounded(gist, in: mail.subject + "\n" + (mail.text ?? "")), "the model said \(gist)")
        for word in Self.examples { #expect(!gist.contains(word), "the model said \(gist)") }
    }

    /// The rules read the newest 300 of the inbox at each run, and its
    /// older threads a share at a time after it, so a split by kind gathers
    /// the whole inbox: a receipt of last year is Receipts' too.
    @Test func olderInboxThreadsAreReadTooAShareAtATime() async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("mail-backfill-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MailStore(file: folder.appendingPathComponent("mail.sqlite"))
        store.set("me", "me@example.com")
        var mail: [MailMessage] = []
        for n in 0..<350 {
            let receipt = n >= 300
            mail.append(MailMessage(id: "r\(n)", thread: "t\(n)", from: MailPerson.one(receipt ? "Shop <billing@shop.example>" : "Ana <ana@pereira.pt>")!,
                                    subject: receipt ? "Your receipt #\(n)" : "Lunch \(n)?", snippet: receipt ? "Your receipt for order \(n)." : "Lunch?",
                                    date: Self.now.addingTimeInterval(Double(-n) * 3600 - 86_400), labels: ["INBOX"]))
        }
        store.put(mail)
        #expect(store.unsensedInbox(limit: 1000).count == 350)
        await MailSense.run(store, now: Self.now, model: false) {}
        // The newest 300 by the run, the 50 older by its share after.
        #expect(store.unsensedInbox(limit: 1000).isEmpty)
        #expect(store.sensed("t349")?.kind == .invoice && store.sensed("t0")?.kind == .person)
        // A share at a time.
        store.put([MailMessage(id: "x1", thread: "x", from: MailPerson.one("Shop <billing@shop.example>")!, subject: "Your receipt",
                               snippet: "Receipt.", date: Self.now.addingTimeInterval(-400 * 86_400), labels: ["INBOX"])])
        #expect(MailSense.backfill(store, now: Self.now, limit: 1) == 1)
        #expect(MailSense.backfill(store, now: Self.now) == 0)
    }

    @Test func repliesWrittenAheadAreReadFromWhateverClaudeSays() {
        let said = "Here you go:\n{\"ta\": [\"Thursday at 3 works \u{2014} see you.\", \"Friday is better.\", \"\", \"Next week?\", \"extra\"], \"tb\": \"not a list\"}"
        let replies = MailDrafts.parse(said)
        #expect(replies["ta"] == ["Thursday at 3 works , see you.", "Friday is better.", "Next week?"])
        #expect(replies["tb"] == nil)
        #expect(MailDrafts.parse("no json here").isEmpty)
    }

    @Test func rowsOnTheNewTab() {
        let now = Self.now
        func notice(_ who: String, _ why: Noticing.MailNotice.Why, ago: Double, due: Date? = nil, gist: String = "") -> Noticing.MailNotice {
            Noticing.MailNotice(account: "me@example.com", thread: who.lowercased(), who: who, host: "example.com", subject: "About \(who)",
                                gist: gist, last: now.addingTimeInterval(-ago * 86_400), due: due, why: why)
        }
        let rows = Noticing.mail([
            notice("Tim", .noAnswer, ago: 5),
            notice("Priya", .waitingOnYou, ago: 1.2),
            notice("Ledgerly", .pastDue, ago: 0.2, gist: "Says the card was declined, $1,240 due"),
            notice("Mark", .due, ago: 0.1, due: now.addingTimeInterval(5 * 3600), gist: "Wants September MAU and revenue"),
        ], now: now)
        #expect(rows.map(\.title) == ["Wants September MAU and revenue", "Says the card was declined, $1,240 due", "Priya is waiting on your reply"])
        #expect(rows[0].detail == "Mark · in 5h")
        #expect(rows[0].due != nil)
        #expect(rows[2].detail == Noticing.age(now.addingTimeInterval(-1.2 * 86_400), now: now) + " · About Priya")
        // Someone answering you comes before someone new, in their words.
        var danny = notice("Danny", .waitingOnYou, ago: 0.2, gist: "Says autofill still shows NordPass locked")
        danny.conversation = true
        let people = Noticing.mail([notice("Priya", .waitingOnYou, ago: 1.2), danny], now: now)
        #expect(people.map(\.title) == ["Danny says autofill still shows NordPass locked", "Priya is waiting on your reply"])
        // Three clinics answering one ask: one row, the newest, and the newest
        // answers first, before an older one.
        func clinic(_ who: String, ago: Double) -> Noticing.MailNotice {
            var one = notice(who, .waitingOnYou, ago: ago)
            one.subject = who == "Kos" ? "Re: Local https pages" : (who == "Ortho" ? "Re: Retainer cost" : "RE: Retainer cost")
            one.conversation = true
            return one
        }
        let quotes = Noticing.mail([clinic("Ortho", ago: 2), clinic("Dixon", ago: 1.8), clinic("Gold", ago: 1), clinic("Kos", ago: 0.6)], now: now)
        #expect(quotes.map(\.title) == ["Kos is waiting on your reply", "Gold is waiting on your reply"])
        #expect(quotes[1].detail.contains("3 replies · "))
        #expect(rows[0].url?.absoluteString == "yab://mail#thread=me@example.com%7Cmark")
        // Rows without a date stay in the queue too, after what is due.
        let ordered = Hints.order(found: [], noticed: rows, setup: [], now: now)
        #expect(ordered.map(\.id) == ["mail.mark", "mail.ledgerly", "mail.priya"])
    }
}
