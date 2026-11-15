import Foundation
import Testing
@testable import Fast

// What a whole form's boxes get (FormRules), the shapes a handle takes
// (Profile.value), and questions known again by their words (FormAnswers).
struct FormTests {
    static let mira: Profile = {
        var p = Profile()
        p.name = "Mira Lindqvist"
        p.headline = "Founding designer at Tern"
        p.company = "Tern Labs"
        p.role = "Founding Designer"
        p.location = "Stockholm, Sweden"
        p.linkedin = "https://www.linkedin.com/in/miralindqvist/"
        p.x = "@miralq"
        p.github = "github.com/miralq"
        p.website = "mira.design"
        p.bio = "I design calm tools for small studios."
        return p
    }()

    static func box(_ label: String, tag: String = "input", type: String = "", kind: String = "", placeholder: String = "",
                    options: [String] = [], checked: Bool = false, maxLength: Int = 0, index: Int = 0) -> FormField {
        var f = FormField()
        f.index = index
        f.label = label
        f.tag = tag
        f.type = type
        f.kind = kind
        f.placeholder = placeholder
        f.options = options
        f.checked = checked
        f.empty = type == "checkbox" ? !checked : true
        f.maxLength = maxLength
        return f
    }

    static func source(_ field: FormField, answers: FormAnswers.Book = .init(), address: Bool = true, known: [String: String] = [:]) -> FormSource {
        FormRules.step(field, profile: mira, answers: answers, site: "lu.ma", hasAddress: address, known: known).source
    }

    @Test func aLumaFormIsTheProfile() {
        #expect(Self.source(Self.box("Company")) == .profile("company"))
        #expect(Self.source(Self.box("Job title")) == .profile("role"))
        // A job title said only by autocomplete's organization-title is the
        // role, never the company its "organization" would match.
        #expect(Self.source(Self.box("Job title", kind: "organization-title")) == .profile("role"))
        #expect(Self.source(Self.box("Company", kind: "organization")) == .profile("company"))
        #expect(Self.source(Self.box("What's your role?")) == .profile("role"))
        #expect(Self.source(Self.box("LinkedIn URL")) == .profile("linkedin"))
        #expect(Self.source(Self.box("Twitter / X handle", placeholder: "@username")) == .profile("x"))
        #expect(Self.source(Self.box("X (Twitter)")) == .profile("x"))
        #expect(Self.source(Self.box("Personal website", type: "url")) == .profile("website"))
        #expect(Self.source(Self.box("GitHub")) == .profile("github"))
        #expect(Self.source(Self.box("Where are you based?")) == .profile("location"))
    }

    @Test func aTalkTitleIsNotAJobTitle() {
        #expect(Self.source(Self.box("Talk title")) != .profile("role"))
        #expect(Self.source(Self.box("Company size", tag: "select", options: ["1-10", "11-50"])) == .yours("choice"))
    }

    @Test func handlesTakeTheShapeTheBoxAsks() {
        let p = Self.mira
        #expect(p.value("x", shape: Self.box("X handle", placeholder: "@username")) == "@miralq")
        #expect(p.value("x", shape: Self.box("Twitter username", placeholder: "username")) == "miralq")
        #expect(p.value("x", shape: Self.box("Twitter profile URL", type: "url")) == "https://x.com/miralq")
        #expect(p.value("linkedin", shape: Self.box("LinkedIn", placeholder: "linkedin.com/in/…")) == "linkedin.com/in/miralindqvist")
        #expect(p.value("linkedin", shape: Self.box("LinkedIn profile")) == "https://www.linkedin.com/in/miralindqvist")
        #expect(p.value("github", shape: Self.box("GitHub username")) == "miralq")
        #expect(p.value("website", shape: Self.box("Website", type: "url")) == "https://mira.design")
        #expect(Profile.handle("https://x.com/miralq/") == "miralq")
        #expect(Profile.handle("@miralq") == "miralq")
    }

    @Test func moneyBanksIdsAndConsentStayYours() {
        #expect(Self.source(Self.box("Salary expectation (SEK / month)")) == .yours("money"))
        #expect(Self.source(Self.box("IBAN for expenses")) == .yours("bank"))
        #expect(Self.source(Self.box("Passport number")) == .yours("id"))
        #expect(Self.source(Self.box("Date of birth", type: "date")) == .yours("self"))
        #expect(Self.source(Self.box("Dietary restrictions")) == .yours("self"))
        #expect(Self.source(Self.box("I agree to the terms", type: "checkbox")) == .yours("consent"))
        #expect(Self.source(Self.box("Password", type: "password")) == .yours("secret"))
    }

    @Test func thePagesOwnMailTickGoes() {
        #expect(Self.source(Self.box("Send me Kiln's newsletter", type: "checkbox", checked: true)) == .untick)
        #expect(Self.source(Self.box("Send me Kiln's newsletter", type: "checkbox", checked: false)) == .skip)
        #expect(Self.source(Self.box("Remember me", type: "checkbox", checked: true)) == .skip)
    }

    @Test func anAddressIsTheWallets() {
        #expect(Self.source(Self.box("Email", type: "email", kind: "email")) == .wallet)
        #expect(Self.source(Self.box("Street", kind: "line1")) == .wallet)
        // No address kept: a name box still takes the profile's name.
        #expect(Self.source(Self.box("First name", kind: "given"), address: false) == .profile("name"))
        #expect(FormRules.step(Self.box("First name", kind: "given"), profile: Self.mira, answers: .init(), site: "x", hasAddress: false, known: [:]).value == "Mira")
        // A company box is the profile's when it knows one.
        #expect(Self.source(Self.box("Company", kind: "org")) == .profile("company"))
    }

    @Test func aQuestionAnsweredBeforeIsAnsweredAgain() {
        var book = FormAnswers.Book()
        book.said = [FormAnswers.Said(question: FormAnswers.normal("What are you working on?"), answer: "A calm scheduling tool.", site: "lu.ma", at: .now)]
        #expect(Self.source(Self.box("What are you working on? *"), answers: book) == .answer("A calm scheduling tool."))
        #expect(Self.source(Self.box("What are you hoping to get out of tonight?")) == .draft)
        #expect(Self.source(Self.box("Anything else?", tag: "textarea")) == .draft)
        // A choice answered before goes to the same option.
        book.said.append(.init(question: FormAnswers.normal("How did you hear about us?"), answer: "A friend", site: "lu.ma", at: .now))
        let heard = FormRules.step(Self.box("How did you hear about us?", tag: "select", options: ["LinkedIn", "A friend", "Other"]),
                                   profile: Self.mira, answers: book, site: "lu.ma", hasAddress: true, known: [:])
        #expect(heard.source == .answer("A friend"))
        #expect(heard.value == "A friend")
    }

    @Test func questionsAreKnownByTheirWords() {
        #expect(FormAnswers.normal("What are you working on? *") == "what are you working on")
        #expect(FormAnswers.normal("What are you working on (optional)") == "what are you working on")
        #expect(FormAnswers.normal("  Company / Organization:") == "company organization")
    }

    @Test func whatTheMacLearnedCounts() {
        let odd = Self.box("Where can we find you online?")
        #expect(Self.source(odd) == .draft)
        #expect(Self.source(odd, known: [FormAnswers.normal(odd.label): "website"]) == .profile("website"))
        // Never past what the dictionary rules out.
        #expect(Self.source(Self.box("Company size"), known: ["company size": "company"]) == .yours("none"))
        let short = Self.box("Day job")
        #expect(Self.source(short) == .yours("none"))
        #expect(Self.source(short, known: ["day job": "company"]) == .profile("company"))
    }

    @Test func aPlanCountsWhatAPersonSees() {
        let fields = [
            Self.box("Name", kind: "name", index: 0), Self.box("Email", type: "email", kind: "email", index: 1),
            Self.box("Company", index: 2), Self.box("LinkedIn", index: 3),
            Self.box("What are you hoping to get out of tonight?", tag: "textarea", index: 4),
            Self.box("Want a demo slot?", type: "radio", options: ["Yes", "No"], index: 5),
            Self.box("I agree to share my info", type: "checkbox", index: 6),
        ]
        let plan = FormRules.plan(fields, profile: Self.mira, answers: .init(), site: "lu.ma", hasAddress: true)
        #expect(plan.boxes == 6)
        #expect(plan.filling == 5)
        #expect(plan.yours == 1)
        #expect(plan.drafts.count == 1)
        #expect(plan.beyondAddress == 3)
    }

    @Test func draftsComeBackAsAList() {
        #expect(FormDraft.parse("Here you go:\n[\"One.\", \"Two \u{2014} three.\"]") == ["One.", "Two , three."])
        #expect(FormDraft.parse("no list").isEmpty)
    }
}

extension FormTests {
    @Test func aMessageToOneSiteStaysThere() {
        var book = FormAnswers.Book()
        book.said = [
            .init(question: FormAnswers.normal("Message"), answer: "My card was charged twice, account 4471.", site: "bank.com", at: .now),
            .init(question: FormAnswers.normal("What are you working on?"), answer: "A calm scheduling tool.", site: "lu.ma", at: .now),
            .init(question: FormAnswers.normal("Why do you want to join us?"), answer: String(repeating: "Long answer. ", count: 30), site: "tern.com", at: .now),
        ]
        #expect(book.answer(to: "Message", site: "bank.com") != nil)
        #expect(book.answer(to: "Message", site: "jobs.example") == nil)
        // Nothing goes to another site, however short and particular.
        #expect(book.answer(to: "What are you working on?", site: "other.example") == nil)
        #expect(book.answer(to: "What are you working on?", site: "lu.ma") == "A calm scheduling tool.")
        #expect(book.answer(to: "Why do you want to join us?", site: "other.example") == nil)
        // Longer than a line, not even on its own site.
        #expect(book.answer(to: "Why do you want to join us?", site: "tern.com") == nil)
    }

    /// A form about a piece of work, hiring a freelancer: the position and
    /// the work are the project's, your name, company and email yours.
    /// The brief written for the last freelancer stays out, here too.
    @Test func aHiringFormIsNotAboutYou() {
        let about = "post a project · talentdock · post a project · post project"
        var book = FormAnswers.Book()
        book.said = [.init(question: FormAnswers.normal("Describe the work"), answer: "Landing page, three sections.", site: "talentdock.com", at: .now)]
        func src(_ f: FormField) -> FormSource {
            FormRules.step(f, profile: Self.mira, answers: book, site: "talentdock.com", hasAddress: true, known: [:], about: about).source
        }
        #expect(src(Self.box("Position you're hiring for")) == .yours("other"))
        #expect(src(Self.box("Job title")) == .yours("other"))
        #expect(src(Self.box("Describe the work", tag: "textarea")) == .yours("other"))
        #expect(src(Self.box("What do you need done?", tag: "textarea")) == .yours("other"))
        #expect(src(Self.box("When should it start?")) == .yours("other"))
        #expect(src(Self.box("Budget (USD)")) == .yours("money"))
        #expect(src(Self.box("Your company")) == .profile("company"))
        #expect(src(Self.box("Your name", kind: "name")) == .wallet)
        #expect(src(Self.box("Email", type: "email", kind: "email")) == .wallet)
    }

    /// A form about another person: even its name and email are theirs.
    @Test func aFormAboutSomeoneElseIsTheirs() {
        let about = "send a gift · shop · gift message · send gift"
        func src(_ f: FormField) -> FormSource {
            FormRules.step(f, profile: Self.mira, answers: .init(), site: "shop.com", hasAddress: true, known: [:], about: about).source
        }
        #expect(src(Self.box("Name", kind: "name")) == .yours("other"))
        #expect(src(Self.box("Email", type: "email", kind: "email")) == .yours("other"))
        #expect(src(Self.box("Your email", type: "email", kind: "email")) == .wallet)
        // Anywhere, a box that names someone else is theirs.
        #expect(Self.source(Self.box("Recipient's company")) == .yours("other"))
        #expect(Self.source(Self.box("Emergency contact name")) == .yours("other"))
        // A form about you is untouched: an event's, an application's.
        let event = "ai agents night sf · luma · request to join"
        #expect(FormRules.step(Self.box("Job title"), profile: Self.mira, answers: .init(), site: "lu.ma", hasAddress: true, known: [:], about: event).source == .profile("role"))
        let apply = "apply · founding designer · tern · send application"
        #expect(FormRules.step(Self.box("Why Tern?", tag: "textarea"), profile: Self.mira, answers: .init(), site: "tern.com", hasAddress: true, known: [:], about: apply).source == .draft)
    }

    /// A sent form keeps what isn't kept yet, and never what is the
    /// Wallet's, the profile's or only yours.
    @Test func aSentFormKeepsWhatIsNew() {
        var book = FormAnswers.Book()
        book.said = [.init(question: FormAnswers.normal("How did you hear about us?"), answer: "A friend", site: "lu.ma", at: .now)]
        let long = String(repeating: "I build calm tools for small studios. ", count: 5)
        let sent: [(field: FormField, answer: String)] = [
            (Self.box("Email", type: "email", kind: "email"), "jane@example.com"),
            (Self.box("Company"), "Tern Labs"),
            (Self.box("How did you hear about us?"), "A friend"),
            (Self.box("What are you working on?"), "A calm scheduling tool."),
            (Self.box("Why do you want to come?", tag: "textarea"), long),
            (Self.box("Expected salary"), "120000"),
            (Self.box("Passport number"), "X1234567"),
            (Self.box("Date of birth"), "1990-01-01"),
            (Self.box("Password", type: "password"), "hunter2"),
            (Self.box("Team size"), "   "),
        ]
        let fresh = FormAnswers.fresh(sent, book: book, profile: Self.mira, site: "lu.ma")
        // The company is the profile's, the way it heard of it is kept already.
        #expect(fresh.map(\.label) == ["What are you working on?", "Why do you want to come?"])
        // Another company than the profile's is an answer; changed words are kept again.
        let changed = FormAnswers.fresh([(Self.box("Company"), "Northwind"), (Self.box("How did you hear about us?"), "A newsletter")],
                                        book: book, profile: Self.mira, site: "lu.ma")
        #expect(changed.map(\.answer) == ["Northwind", "A newsletter"])
        // On another site the same answer is new: answers stay on their own site.
        #expect(FormAnswers.fresh([(Self.box("How did you hear about us?"), "A friend")], book: book, profile: Self.mira, site: "other.example").count == 1)
    }

    /// A long answer reads as one-off and is never filled again, kept by
    /// the morning look or not; a short one is filled at once.
    @Test func aLongAnswerIsNeverFilledAgain() {
        let long = String(repeating: "I build calm tools for small studios. ", count: 5)
        var book = FormAnswers.Book()
        book.said = [
            .init(question: FormAnswers.normal("What are you working on?"), answer: "A calm scheduling tool.", site: "lu.ma", at: .now, fresh: true),
            .init(question: FormAnswers.normal("Why do you want to come?"), answer: long, site: "lu.ma", at: .now, fresh: true),
        ]
        #expect(book.answer(to: "What are you working on?", site: "lu.ma") == "A calm scheduling tool.")
        #expect(book.answer(to: "Why do you want to come?", site: "lu.ma") == nil)
        #expect(!book.questions.contains("why do you want to come"))
        book.said[1].fresh = nil
        #expect(book.answer(to: "Why do you want to come?", site: "lu.ma") == nil)
        #expect(book.questions.contains("why do you want to come"))
        // An id is short, and the same for the same question on the same site.
        #expect(book.said[0].id.count <= 8 && book.said[0].id == book.said[0].id)
        #expect(book.said[0].id != book.said[1].id)
    }

    /// A filled box says where its value came from, in a color and a few words.
    @Test func aFilledBoxSaysWhereItCameFrom() {
        var home = StreetAddress(id: "a")
        home.street = "221 Mission St\nApt 4"
        #expect(FormSource.wallet.dot(address: home)! == ("green", "Wallet · 221 Mission St"))
        #expect(FormSource.profile("linkedin").dot()! == ("accent", "Profile · LinkedIn"))
        #expect(FormSource.profile("role").dot()! == ("accent", "Profile · Title"))
        #expect(FormSource.answer("A friend").dot()! == ("gray", "As last time"))
        #expect(FormSource.draft.dot()?.color == "accent")
        #expect(FormSource.yours("money").dot() == nil)
        #expect(FormSource.untick.dot() == nil)
    }

    /// A file box's Recent rows filter by `accept` and merge the same path.
    @MainActor @Test func aFileBoxGetsTheNewestThatFit() throws {
        let pdf = URL(fileURLWithPath: "/tmp/Resume.pdf"), png = URL(fileURLWithPath: "/tmp/me.PNG"), archive = URL(fileURLWithPath: "/tmp/a.zip")
        #expect(RecentFiles.accepts(pdf, [".pdf", ".doc"]))
        #expect(RecentFiles.accepts(pdf, ["application/pdf"]))
        #expect(!RecentFiles.accepts(png, [".pdf"]))
        #expect(RecentFiles.accepts(png, ["image/*"]))
        #expect(RecentFiles.accepts(png, [" image/png "]))
        #expect(!RecentFiles.accepts(archive, ["image/*", ".pdf"]))
        #expect(RecentFiles.accepts(archive, []))

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["old.pdf", "cv.pdf", "photo.jpg", "notes.txt", ".hidden.pdf", "half.pdf.crdownload", "a.pdf", "b.pdf", "c.pdf"]
        for (n, name) in names.enumerated() {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(n) * 100)], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("folder.pdf"), withIntermediateDirectories: true)
        let found = RecentFiles.look(in: [(folder, "Downloads")], kept: [folder.appendingPathComponent("cv.pdf")])
        #expect(!found.contains { $0.name.hasPrefix(".") || $0.name.hasSuffix("crdownload") || $0.name == "folder.pdf" })
        let pdfs = FileRows.rows(kept: [], recent: found, host: "acme.com", accept: [".pdf"], now: Date())
        #expect(pdfs.count == 5)
        #expect(pdfs.allSatisfy { $0.section == "Recent" && $0.title.hasSuffix(".pdf") })
        #expect(Set(pdfs.map(\.id)).count == pdfs.count)
        #expect(FileRows.rows(kept: [], recent: found, host: "acme.com", accept: ["image/*"], now: Date()).map(\.title) == ["photo.jpg"])
        #expect(pdfs.first?.source.hasPrefix("Downloads · ") == true)
    }

    /// A folder Files is kept to lists all it fits, newest first, one
    /// kept from a download with its site, under the folder's own words.
    @MainActor @Test func aFolderListsWhatFitsNewestFirst() throws {
        let now = Date()
        let folder = URL(fileURLWithPath: "/tmp/yab-folder")
        let files = (0..<12).map { n in
            RecentFile(url: folder.appendingPathComponent("f\(n).\(n == 5 ? "png" : "pdf")"), added: now.addingTimeInterval(-Double(n) * 3600),
                       size: 2048, place: "Documents")
        }
        let keep = Keep(name: "f3.pdf", from: "acme.com", path: files[3].url.path, date: now.addingTimeInterval(-600),
                        page: URL(string: "https://acme.com/order"), pageTitle: "Order")
        let rows = FileRows.folder(files.shuffled(), kept: [keep], title: "Documents", accept: [".pdf"], now: now)
        #expect(rows.map(\.title) == files.filter { $0.url.pathExtension == "pdf" }.map(\.name))
        #expect(rows.allSatisfy { $0.section == "In Documents" })
        #expect(rows.first?.source == "just now · 2 KB")
        #expect(rows.first { $0.title == "f3.pdf" }?.source == "Downloaded from acme.com 10m ago")
        #expect(FileRows.folder(files, kept: [], title: "Desktop", accept: [], now: now).first?.section == "On the Desktop")

        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(RecentFiles.title(of: home.appendingPathComponent("Downloads")) == "Downloads")
        #expect(RecentFiles.title(of: home.appendingPathComponent("Documents/Work/Invoices")) == "Work › Invoices")
        #expect(RecentFiles.title(of: URL(fileURLWithPath: "/Volumes/Disk/Scans")) == "Scans")
    }

    @MainActor @Test func filePlaceKeepsSiteAndMergesDownloads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-file-place-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date()
        let siteURL = folder.appendingPathComponent("receipt.pdf")
        let otherURL = folder.appendingPathComponent("old.pdf")
        let shotURL = folder.appendingPathComponent("Screenshot 1.png")
        let imageURL = folder.appendingPathComponent("site-image.png")
        for url in [siteURL, otherURL, shotURL, imageURL] { try Data("x".utf8).write(to: url) }
        let keep = Keep(name: "receipt.pdf", from: "acme.com", path: siteURL.path, date: now.addingTimeInterval(-120),
                        page: URL(string: "https://acme.com/order"), pageTitle: "Order")
        let imageKeep = Keep(name: "site-image.png", from: "acme.com", path: imageURL.path, date: now.addingTimeInterval(-90),
                             page: URL(string: "https://acme.com/order"), pageTitle: "Order")
        let recent = [RecentFile(url: siteURL, added: now.addingTimeInterval(-60), size: 1, place: "Downloads"),
                      RecentFile(url: otherURL, added: now.addingTimeInterval(-180), size: 1, place: "Desktop"),
                      RecentFile(url: shotURL, added: now.addingTimeInterval(-30), size: 1, place: "Desktop", capture: true)]
        let pdf = FileRows.rows(kept: [keep], recent: recent, host: "acme.com", accept: [".pdf"], now: now)
        #expect(pdf.map(\.title) == ["receipt.pdf", "old.pdf"])
        #expect(pdf.map(\.section) == ["Now", "Recent"])
        #expect(pdf[0].source.contains("Downloaded from this site"))
        let images = FileRows.rows(kept: [keep, imageKeep], recent: recent, host: "acme.com", accept: ["image/*"], now: now)
        #expect(images.prefix(2).map(\.title) == ["site-image.png", "Screenshot 1.png"])
        #expect(images.prefix(2).allSatisfy { $0.section == "Now" })
        let otherSite = FileRows.rows(kept: [keep], recent: recent, host: "elsewhere.com", accept: [".pdf"], now: now)
        #expect(otherSite.count == 2)
        #expect(otherSite.allSatisfy { $0.section == "Recent" })
    }

    @Test func screenshotsAreKnownByTheMarkOrAnAppsNameButNotWhenDownloaded() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-shots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func make(_ name: String, _ attribute: String? = nil) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            if let attribute {
                let value = Data("1".utf8)
                _ = value.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, value.count, 0, 0) }
            }
            return url
        }
        #expect(RecentFiles.captured(try make("window.png", "com.apple.metadata:kMDItemIsScreenCapture")))
        #expect(RecentFiles.captured(try make("Screenshot 2026-10-14 at 15.51.10.png")))
        #expect(RecentFiles.captured(try make("CleanShot 2026-10-14 at 15.51.10@2x.png")))
        #expect(RecentFiles.captured(try make("Bildschirmfoto 2026-10-14 um 15.51.10.png")))
        #expect(!RecentFiles.captured(try make("Screenshot from a site.png", "com.apple.quarantine")))
        #expect(!RecentFiles.captured(try make("Screenshot sent.png", "com.apple.metadata:kMDItemWhereFroms")))
        #expect(!RecentFiles.captured(try make("photo.png")))
        let found = RecentFiles.look(in: [(folder, "Screenshots")], kept: [])
        #expect(found.filter(\.capture).count == 4)
    }

    @Test func recentTakesTheNewestScreenshotNowAndAtMostThreeMore() {
        let now = Date()
        let folder = URL(fileURLWithPath: "/tmp/yab-recent")
        var recent = (0..<6).map { n in
            RecentFile(url: folder.appendingPathComponent("Screenshot \(n).png"), added: now.addingTimeInterval(-Double(n + 1) * 60),
                       size: 1, place: n == 0 ? "Downloads" : "Screenshots", capture: true)
        }
        recent.append(RecentFile(url: folder.appendingPathComponent("invoice.pdf"), added: now.addingTimeInterval(-3600), size: 1, place: "Downloads"))
        let rows = FileRows.rows(kept: [], recent: recent, host: "", accept: [], now: now)
        #expect(rows.first?.title == "Screenshot 0.png")
        #expect(rows.first?.section == "Now")
        #expect(rows.filter { $0.section == "Recent" }.map(\.title) == ["Screenshot 1.png", "Screenshot 2.png", "Screenshot 3.png", "invoice.pdf"])
        #expect(rows.filter { $0.section == "Recent" }.first?.source.hasPrefix("Screenshots · ") == true)
    }

    @Test func filesSaysWhereItLooked() {
        let at = URL(fileURLWithPath: "/x")
        #expect(RecentFiles.phrase(of: [(at, "Downloads"), (at, "Desktop")], joined: "or") == "in Downloads or on the Desktop")
        #expect(RecentFiles.phrase(of: [(at, "Downloads"), (at, "Desktop"), (at, "Screenshots")], joined: "and")
                == "in Downloads, on the Desktop and in Screenshots")
    }

    @MainActor @Test func pastedFilePathsFindUnindexedFilesAndSurviveRowFiltering() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-path-\(UUID().uuidString)")
        let nested = folder.appendingPathComponent("launch images/all")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = nested.appendingPathComponent("agent result short.jpg")
        try Data("image".utf8).write(to: file)
        let search = FileSearch()
        func find(_ words: String, accept: [String] = ["image/*"]) async -> [URL] {
            await withCheckedContinuation { continuation in
                search.start(words, accept: accept, in: folder.appendingPathComponent("elsewhere")) {
                    continuation.resume(returning: $0)
                }
            }
        }
        let row = PlaceItem(id: "file." + file.path, section: "On This Mac", title: file.lastPathComponent,
                            source: "all", tile: .file(file.path), what: .file(file))
        for words in [file.path, "  \(file.path)\n", "\"\(file.path)\"", "'\(file.path)'", file.absoluteString] {
            let found = await find(words)
            #expect(found.map(\.path) == [file.path])
            #expect(FileRows.matches(row, words: words))
        }
        let wrongType = await find(file.path, accept: [".pdf"])
        let directory = await find(nested.path, accept: [])
        let missing = await find(nested.appendingPathComponent("missing.jpg").path)
        #expect(wrongType.isEmpty)
        #expect(directory.isEmpty)
        #expect(missing.isEmpty)
        #expect(RecentFiles.path(in: "~/Documents/a.jpg") == RecentFiles.home.appendingPathComponent("Documents/a.jpg").standardizedFileURL)
        #expect(RecentFiles.path(in: "agent result") == nil)
        #expect(RecentFiles.path(in: "https://example.com/a.jpg") == nil)
        #expect(FileRows.matches(row, words: "agent short"))
        #expect(!FileRows.matches(row, words: nested.appendingPathComponent("other.jpg").path))
        let keep = Keep(name: file.lastPathComponent, from: "example.com", path: file.path, date: Date())
        let keptRow = PlaceItem(id: row.id, section: "Recent", title: row.title, source: "Downloaded",
                                tile: .file(file.path), what: .kept(keep))
        #expect(FileRows.matches(keptRow, words: file.path))
    }

    @MainActor @Test func fileSearchPredicateUsesNameAndAcceptedType() {
        let query = FileSearch.predicate(words: "receipt", accept: [".pdf"])
        let metadata = NSMetadataQuery()
        metadata.predicate = query
        #expect(metadata.predicate != nil)
        metadata.predicate = FileSearch.predicate(words: "receipt", accept: [])
        metadata.predicate = FileSearch.predicate(words: "receipt", accept: [".pdf", "image/*"])
        #expect(query.evaluate(with: [NSMetadataItemFSNameKey: "receipt.pdf"]))
        #expect(!query.evaluate(with: [NSMetadataItemFSNameKey: "receipt.png"]))
        #expect(!query.evaluate(with: [NSMetadataItemFSNameKey: "other.pdf"]))
    }
}
