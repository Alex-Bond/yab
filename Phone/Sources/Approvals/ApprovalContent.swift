import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// A question from a Mac shaped for the tray: who or what it is about (the
/// site, the person, the files), the thing itself, and the yes in words. The
/// request's lines are all an older Mac sends; its detail, when it came, is
/// the whole thing.
struct ApprovalContent: Equatable {
    enum Kind: Equatable {
        /// A payment, as the Mac's pay sheet: card, address, total.
        case pay
        /// Several mails, or mail being changed: rows that open.
        case mails
        /// One mail going: its paper, Show All.
        case mail
        /// Files going to a page: their pages.
        case files
        /// A message to someone: the bubble it will be.
        case message
        /// A mail search for the whole chat: its first look, the terms.
        case search
        /// A sign-in: one row an account.
        case accounts
        /// Anything else: its words, as the Mac wrote them.
        case lines
    }

    /// What the head shows on the left.
    enum Mark: Equatable {
        case site(String)
        case person(String)
        case messages
        case files
        case mail
    }

    /// One thing in a list that opens into the window: a mail, a refund.
    struct Item: Equatable, Identifiable {
        let id: String
        var title: String
        var subtitle: String
        var snippet: String
        var initials: String
        var tint: Color
        var amount: String?
        var mail: AssistantApprovalRecords.Detail.Mail?
    }

    var kind: Kind
    var mark: Mark
    var name: String
    var sub: String
    var question: String?
    var verb: String
    var chat: Bool
    var items: [Item] = []
    var files: [AssistantApprovalRecords.Detail.File] = []
    var pay: AssistantApprovalRecords.Detail.Pay?
    var accounts: [String] = []
    var lines: [String] = []
    var text: String?
    /// A search's first look: the query, or a mail's subject (`opens`).
    var search: (words: String, opens: Bool)? {
        get { searchWords.map { ($0, searchOpens) } }
        set { searchWords = newValue?.words; searchOpens = newValue?.opens ?? false }
    }
    private var searchWords: String?
    private var searchOpens = false
    /// The terms the mail is read under, when the Mac said them.
    var terms: String?
    /// Rows shown before "N more" opens the rest as a step.
    var shown: Int { kind == .mails && items.count > 4 ? 3 : items.count }

    init(_ request: AssistantApprovalRecords.Request, detail: AssistantApprovalRecords.Detail?) {
        chat = request.isChat
        let host = request.lines.first.flatMap(Self.host)
        let lines = Array(request.lines.dropFirst(host == nil ? 0 : 1))
        question = request.question
        verb = detail?.verb ?? Self.verb(request)
        if let pay = detail?.pay {
            kind = .pay
            mark = .site(pay.site)
            name = pay.site
            sub = pay.item
            question = nil
            self.pay = pay
            verb = detail?.verb ?? "Pay \(pay.amount)"
        } else if let mails = detail?.mails.flatMap({ $0.isEmpty ? nil : $0 }) ?? Self.batch(lines), !mails.isEmpty {
            let sending = mails.first?.date == nil
            let one = mails.count == 1 && sending
            kind = one ? .mail : .mails
            let first = mails[0]
            if one, let to = first.to.first {
                mark = .person(to.name)
                name = to.name
                sub = first.from.map { "From \($0.address ?? $0.name)" } ?? (host ?? "")
                question = nil
            } else if sending {
                if detail?.verb == nil { verb = "Send All \(mails.count)" }
                // Mail going out is the mail's, not the page the agent is on.
                mark = .mail
                name = "Your mail"
                sub = first.from.map { "From \($0.address ?? $0.name)" } ?? (chat ? "In this chat" : "On your Mac")
            } else {
                mark = chat ? .mail : .site(host ?? "mail.google.com")
                name = chat ? "Your mail" : (host ?? "Mail")
                sub = chat ? "In this chat" : (first.from.map { "From \($0.address ?? $0.name)" } ?? "")
            }
            items = mails.map { mail in
                let who = sending ? (mail.to.first ?? .init(name: "")) : (mail.from ?? .init(name: ""))
                let words = mail.body.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                // A greeting says nothing: the line after it does.
                let snippet = words.count > 1 && words[0].count < 24 ? words[1] : (words.first ?? "")
                return Item(id: mail.id, title: who.name, subtitle: mail.subject, snippet: snippet,
                            initials: Self.initials(who.name), tint: Self.tint(who.name), mail: mail)
            }
        } else if request.permit == "mail.read" {
            kind = .search
            mark = .mail
            name = "Your mail"
            // A chat's question names the chat on its first line.
            let title = request.lines.first.flatMap { $0 == "once for this chat" ? nil : $0 }
            sub = chat ? title.map { "In \u{201C}\($0)\u{201D}" } ?? "In this chat" : "On your Mac"
            let said = (detail?.text ?? "").components(separatedBy: "\n")
            let first = said[0].trimmingCharacters(in: .whitespaces)
            let opens = first.hasPrefix("Opens")
            if let words = Self.quoted(first) { search = (words, opens) }
            else if !first.isEmpty { search = (first, false) }
            let rest = said.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            terms = rest.isEmpty ? nil : rest
            question = "Let \(request.asker) \(opens ? "read" : "search") your mail?"
            verb = detail?.verb ?? "Allow in This Chat"
        } else if let files = detail?.files, !files.isEmpty {
            kind = .files
            mark = .site(host ?? "")
            name = host ?? "Files"
            sub = lines.first ?? ""
            self.files = files
        } else if let text = detail?.text, let person = detail?.person {
            kind = .message
            mark = .person(person.name)
            name = person.name
            sub = "iMessage"
            question = nil
            self.text = text
        } else if let choices = request.choices, !choices.isEmpty {
            kind = .accounts
            mark = .site(host ?? "")
            name = host ?? ""
            sub = "Saved in Yab"
            accounts = choices
            verb = "Sign In"
        } else {
            kind = .lines
            mark = chat ? .mail : .site(host ?? "")
            name = chat ? (request.permit.hasPrefix("mail") ? "Your mail" : "This chat") : (host ?? "Your Mac")
            sub = chat ? "In this chat" : "On your Mac"
            self.lines = lines
            text = detail?.text
        }
    }

    /// "Yab 0.32" out of "Looks for “Yab 0.32”".
    static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\u{201C}"), let close = line.lastIndex(of: "\u{201D}"), open < close else { return nil }
        let words = line[line.index(after: open)..<close]
        return words.isEmpty ? nil : String(words)
    }

    /// Mails as an older Mac writes them into a question's lines, with no
    /// detail: "1. To anna@studio.co · Re: Plans" over each one's words. The
    /// words stop where the Mac cut them.
    static func batch(_ lines: [String]) -> [AssistantApprovalRecords.Detail.Mail]? {
        guard let text = lines.first(where: { $0.hasPrefix("1. To ") }) else { return nil }
        var mails: [AssistantApprovalRecords.Detail.Mail] = []
        var head: String?
        var body: [String] = []
        func close() {
            guard let head else { return }
            let parts = head.components(separatedBy: " · ")
            var to: [AssistantApprovalRecords.Detail.Person] = []
            var cc: [AssistantApprovalRecords.Detail.Person] = []
            var bcc: [AssistantApprovalRecords.Detail.Person] = []
            var subject = ""
            for part in parts {
                func people(_ title: String) -> [AssistantApprovalRecords.Detail.Person]? {
                    guard part.hasPrefix(title + " ") else { return nil }
                    return part.dropFirst(title.count + 1).split(separator: ",").map {
                        let address = $0.trimmingCharacters(in: .whitespaces)
                        return .init(name: address, address: address)
                    }
                }
                if let found = people("To") { to = found }
                else if let found = people("Cc") { cc = found }
                else if let found = people("Bcc") { bcc = found }
                else if subject.isEmpty, !part.hasPrefix("Files "), !part.hasPrefix("Sends ") { subject = part }
            }
            let words = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            mails.append(.init(id: "batch\(mails.count)", to: to, cc: cc, bcc: bcc.isEmpty ? nil : bcc, subject: subject, body: words, files: []))
        }
        for line in text.components(separatedBy: "\n") {
            let number = "\(mails.count + (head == nil ? 1 : 2)). To "
            if line.hasPrefix(number) {
                close()
                head = String(line.dropFirst(number.count - 3))
                body = []
            } else {
                body.append(line)
            }
        }
        close()
        guard mails.count > 1, mails.allSatisfy({ !$0.to.isEmpty }) else { return nil }
        // Over them, who each goes to as the Mac names them: "To Dane Kapoor; ilya@…".
        if let names = lines.first(where: { $0.hasPrefix("To ") })?.dropFirst(3).components(separatedBy: "; "), names.count == mails.count {
            for (index, name) in names.enumerated() where !name.contains("@") && !name.isEmpty { mails[index].to[0].name = name }
        }
        // The Mac cut the last one short: say so.
        if text.count >= 600, var last = mails.popLast() {
            last.body += "…"
            mails.append(last)
        }
        return mails
    }

    /// "doordash.com" from a request's first line, when it is one.
    static func host(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.contains(" "), trimmed.contains("."), trimmed.count < 80 else { return nil }
        return trimmed
    }

    static func verb(_ request: AssistantApprovalRecords.Request) -> String {
        if request.choices != nil { return "Sign In" }
        return request.yesLabel
    }

    /// "Anna Petrova <anna@studio.co>", or the name alone.
    static func named(_ person: AssistantApprovalRecords.Detail.Person) -> String {
        person.address.map { "\(person.name) <\($0)>" } ?? person.name
    }

    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "·" }).prefix(2)
        return words.compactMap(\.first).map(String.init).joined().uppercased()
    }

    /// A person's own color, the same for the same name every time.
    static func tint(_ name: String) -> Color {
        let colors: [Color] = [
            Color(red: 0.48, green: 0.35, blue: 0.97), Color(red: 0.94, green: 0.42, blue: 0.0),
            Color(red: 0.0, green: 0.54, blue: 0.48), Color(red: 0.08, green: 0.4, blue: 0.75),
            Color(red: 0.85, green: 0.11, blue: 0.38), Color(red: 0.43, green: 0.3, blue: 0.25),
        ]
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(sum) % colors.count]
    }

    /// What a card is called on a row: "Visa •••• 6411".
    static func cardTitle(_ card: AssistantApprovalRecords.Detail.Card) -> String {
        let brand = card.brand == "American Express" ? "Amex" : card.brand
        return "\(brand) \u{2022}\u{2022}\u{2022}\u{2022} \(card.last4)"
    }
}
