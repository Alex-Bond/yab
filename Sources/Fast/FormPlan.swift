import Foundation

// A whole form, read box by box, and what yab would put in each: an
// address's parts from the Wallet, your company or your X from the
// Profile, what you answered the same question last time, a draft for a
// question only words answer, or nothing, where the answer is only yours
// to give (money, a bank account, a yes to terms, who you are beyond what
// you wrote down).
//
// Pure: the page's script says what the boxes are (WalletRelay, form()),
// this decides, and the script puts the values in. The one guess a
// dictionary can't make, what an odd label asks, goes to the Mac's own
// model (FormModel) and comes back as a kind this file already knows.

/// A box of a form as the page's script describes it.
struct FormField: Equatable {
    /// Its place in the list the script keeps, to fill it by.
    var index = 0
    /// "input", "select", "textarea".
    var tag = "input"
    /// The input's type: "text", "email", "url", "radio", "checkbox"…
    var type = "text"
    /// What the Wallet's script calls it (WalletRelay.kind), "given", "line1", "email".
    var kind = ""
    /// Its label as a person reads it, "What are you working on?".
    var label = ""
    var name = ""
    var placeholder = ""
    var auto = ""
    var required = false
    var maxLength = 0
    /// A select's options, a radio group's choices, in their words.
    var options: [String] = []
    var empty = true
    /// A checkbox ticked as the page came, or the radio chosen.
    var checked = false

    init() {}

    init?(_ any: Any?) {
        guard let d = any as? [String: Any] else { return nil }
        index = PageNumber.int(d["i"]) ?? -1
        guard index >= 0 else { return nil }
        tag = d["tag"] as? String ?? "input"
        type = (d["type"] as? String ?? "text").lowercased()
        kind = d["kind"] as? String ?? ""
        label = (d["label"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        name = d["name"] as? String ?? ""
        placeholder = d["placeholder"] as? String ?? ""
        auto = d["auto"] as? String ?? ""
        required = d["required"] as? Bool ?? false
        maxLength = PageNumber.int(d["maxLength"]) ?? 0
        options = d["options"] as? [String] ?? []
        empty = d["empty"] as? Bool ?? true
        checked = d["checked"] as? Bool ?? false
    }

    /// Everything the page says about it, lower case, one line.
    var hint: String {
        [label, name, placeholder, auto].joined(separator: " ").lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
    }

    /// A box that asks a question in words rather than for a fact.
    var asks: Bool {
        if tag == "textarea" { return true }
        let words = label.split(whereSeparator: \.isWhitespace).count
        return label.hasSuffix("?") || words >= 5
    }
}

/// Where a box's value comes from.
enum FormSource: Equatable {
    /// The Wallet's address fills it (WalletRelay's own address fill).
    case wallet
    /// A key of the Profile, shaped for the box.
    case profile(String)
    /// What you answered the same question before.
    case answer(String)
    /// Words only a model can write, from the profile and the page.
    case draft
    /// A box ticked by the page that only sends you mail: untick it.
    case untick
    /// Left to you, and why.
    case yours(String)
    /// Nothing to do: a box yab has no business with, or already filled.
    case skip

    var fills: Bool {
        switch self {
        case .wallet, .profile, .answer, .draft: return true
        default: return false
        }
    }
}

struct FormStep: Equatable {
    let field: FormField
    var source: FormSource
    /// What goes in, once known: a profile's value, an answer, a draft.
    var value: String?
}

/// What a whole form would get.
struct FormPlan: Equatable {
    var steps: [FormStep]
    /// The Wallet's address would fill some boxes.
    var address: Bool { steps.contains { $0.source == .wallet } }
    /// Boxes yab fills (drafts included, once written).
    var filling: Int { steps.filter { $0.source.fills && $0.field.type != "checkbox" }.count }
    /// Boxes a person sees, the ones that count in "12 of 14".
    var boxes: Int { steps.filter { $0.field.type != "checkbox" && $0.source != .skip }.count }
    var yours: Int { steps.filter { if case .yours = $0.source { return $0.field.type != "checkbox" } else { return false } }.count }
    var drafts: [FormStep] { steps.filter { $0.source == .draft } }
    /// More in it than the Wallet's address list already fills.
    var beyondAddress: Int { steps.filter { $0.source.fills && $0.source != .wallet }.count }
}

enum FormRules {
    // MARK: - what is never ours to fill

    /// Money, bank details, ids, secrets, and who you are beyond what you
    /// wrote down. Filled by the person or not at all.
    static let never: [(String, String)] = [
        ("money", #"salary|compensation|expected (pay|rate)|hourly rate|\bbudget\b|price|amount|how much|\$|€|£"#),
        ("bank", #"\biban\b|\bswift\b|\bbic\b|routing|sort code|account (number|no)|bank"#),
        ("id", #"\bssn\b|social security|passport|national id|tax id|\btin\b|\bvat\b|driver.?s? licen"#),
        ("secret", #"password|passcode|\bpin\b|one.?time|verification code|captcha"#),
        ("card", #"card number|credit card|debit card|\bcvc\b|\bcvv\b|security code|expir"#),
        ("self", #"date of birth|birth ?date|birthday|\bdob\b|\bage\b|gender|\bsex\b|race|ethnic|disabilit|veteran|religio|health|medical|allerg|dietary|criminal|convict|visa status|citizenship|nationality|marital"#),
        ("signature", #"signature|sign here|initials"#),
    ]

    /// A tick that agrees to something: terms, privacy, sharing, "all correct".
    static let consent = #"agree|consent|terms|privacy|policy|confirm|acknowledge|certify|accept|i understand"#

    /// A tick that only sends you mail.
    static let marketing = #"newsletter|marketing|offers|promotion|promo|partners|updates|news|subscribe|sign me up|send me|emails? (from|about)"#

    // MARK: - whose form it is

    /// What a form says it is for, when that is a piece of work: a project
    /// posted, a freelancer hired, a quote asked for. Its boxes are about
    /// the work, and only your own contact boxes and the ones that say
    /// "your" are yours: "Position you're hiring for" is the freelancer's,
    /// never your title, and "Describe the work" is this project's, never
    /// the last one's.
    static let task = #"\bhire\b|hiring|post (a |your )?(new )?(job|project|gig|task|role|listing)|job (post|posting|listing|description)|request (a )?(quote|proposal)|get (a )?quote|project (brief|details|description)|describe (the|your) (project|work|job|task)|find (a )?(freelancer|designer|developer|expert|talent|contractor)"#

    /// A form about another person: a gift's recipient, a friend invited,
    /// a contact or a candidate added. Even its name and email are theirs.
    static let someone = #"send (a )?gift|gift (card|message)|refer (a )?(friend|colleague)|invite (a |your )?(friend|colleague|teammate)|nominate|add (a |new )?(contact|candidate|employee|member|guest|lead|customer|person)|new (contact|candidate|employee|lead|customer)"#

    /// A box that is about someone else, whatever form it is in.
    static let theirs = #"recipient|friend'?s|guest'?s|candidate|freelancer|contractor|employee|referee|emergency contact|nominee|\btheir\b|hiring|for this (role|position|job)|open (role|position)|role you|position you"#

    /// A box that says it is yours.
    static let mine = #"\byour\b|\byou\b|\bmy\b|contact (name|e ?mail|phone|details|info)|about you"#

    /// Your own contact boxes, which a form about a piece of work still asks of you.
    static let contactKinds: Set<String> = ["name", "given", "family", "email", "tel", "telNational", "org"]

    /// The box is about someone or something other than you: nothing of
    /// yours goes in, not the profile, not an answer you gave before.
    /// `about`: the form's own words, lower case.
    static func notYours(_ field: FormField, about: String) -> Bool {
        let words = field.label.isEmpty ? field.hint : field.label.lowercased()
        if matches(words, theirs) { return true }
        // A question in words on a form about a piece of work is about the
        // work, "What do you need done?" too: no draft, no answer from before.
        if field.asks, matches(about, task) { return true }
        if matches(words, mine) { return false }
        if matches(about, someone) { return true }
        return matches(about, task) && !contactKinds.contains(field.kind)
    }

    // MARK: - the profile's words

    /// Profile keys by what a label says, most particular first.
    static let profile: [(String, String, String?)] = [
        ("linkedin", #"linked ?in"#, nil),
        ("github", #"git ?hub"#, nil),
        ("telegram", #"telegram|\btg\b"#, nil),
        ("instagram", #"instagram|\binsta\b"#, nil),
        ("x", #"twitter|x\.com|\bx\s*(\(|/|handle|username|profile|account|link)|\(x\)|x \(twitter\)|twitter ?/ ?x"#, nil),
        ("website", #"website|web site|portfolio|personal (site|url|page|link)|homepage|home page|your site|\burl\b"#, #"linked ?in|twitter|github|company (website|url|site)"#),
        ("company", #"company|organi[sz]ation|employer|where do you work|workplace|startup|business name"#, #"size|industry|type of|website|url|email|\btitle\b"#),
        ("role", #"job title|\btitle\b|\brole\b|position|occupation|what do you do|designation"#, #"talk|session|project|post|article|\bmrs?\b|\bms\b|salutation|prefix|honorific"#),
        ("headline", #"headline|tagline|one.?liner|in one line|elevator pitch"#, nil),
        ("working", #"what are you (working on|building)|what('s| is) your (current )?(project|startup)|currently (working on|building)|current project|what do you build"#, nil),
        ("languages", #"languages? (do )?you speak|spoken languages?|\blanguages?\b"#, #"programming|coding|tech|stack|framework|preferred language for"#),
        ("timezone", #"time ?zone"#, nil),
        ("pronouns", #"pronoun"#, nil),
        ("location", #"\blocation\b|where are you (based|located|from)|where do you live|\bbased in\b|city"#, #"event|venue|preferred|job location|work location"#),
        ("bio", #"\bbio\b|about (you|yourself|me)|tell us about yourself|introduce yourself|describe yourself"#, nil),
    ]

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// The profile key a box asks for, by its words; nil when they say
    /// nothing a dictionary knows.
    static func profileKey(_ field: FormField) -> String? {
        let hint = field.hint
        for (key, yes, no) in profile where matches(hint, yes) {
            if let no, matches(hint, no) { continue }
            return key
        }
        if field.type == "url" { return "website" }
        return nil
    }

    /// What the dictionary says a key is never, "Company size" for company:
    /// the model's guess doesn't get past it.
    static func excluded(_ key: String, _ field: FormField) -> Bool {
        guard let rule = profile.first(where: { $0.0 == key }), let no = rule.2 else { return false }
        return matches(field.hint, no)
    }

    /// Why a box is never ours, or nil.
    static func forbidden(_ field: FormField) -> String? {
        let hint = field.hint
        if field.type == "password" { return "secret" }
        for (why, pattern) in never where matches(hint, pattern) { return why }
        return nil
    }

    /// The Wallet script's own kinds that the address fill takes care of.
    static let walletKinds: Set<String> = [
        "name", "given", "family", "org", "email", "tel", "telNational", "telCode", "telArea", "telLocal",
        "street", "line1", "line2", "line3", "city", "region", "postal", "country",
    ]

    // MARK: - the plan

    /// What each box gets. `hasAddress`: the Wallet keeps one. `known`:
    /// what the Mac's model or an earlier look said an odd label asks,
    /// by the label's words (FormModel).
    /// `about`: what the form says it is for, its page's title, heading
    /// and sending button (`__yabForm.read`).
    static func plan(_ fields: [FormField], profile: Profile, answers: FormAnswers.Book, site: String,
                     hasAddress: Bool, known: [String: String] = [:], about: String = "") -> FormPlan {
        let about = about.lowercased()
        let steps = fields.map { field -> FormStep in
            step(field, profile: profile, answers: answers, site: site, hasAddress: hasAddress, known: known, about: about)
        }
        return FormPlan(steps: steps)
    }

    static func step(_ field: FormField, profile: Profile, answers: FormAnswers.Book, site: String,
                     hasAddress: Bool, known: [String: String], about: String = "") -> FormStep {
        let hint = field.hint
        if field.type == "checkbox" {
            if matches(hint, consent) { return FormStep(field: field, source: .yours("consent")) }
            if field.checked, matches(hint, marketing) { return FormStep(field: field, source: .untick) }
            return FormStep(field: field, source: .skip)
        }
        guard field.empty else { return FormStep(field: field, source: .skip) }
        if let why = forbidden(field) { return FormStep(field: field, source: .yours(why)) }
        if notYours(field, about: about) { return FormStep(field: field, source: .yours("other")) }
        // The address's own boxes: the Wallet's fill, which already knows
        // every shape of a phone or a state. A company box goes to the
        // profile when it knows one.
        if !field.kind.isEmpty, walletKinds.contains(field.kind) {
            if field.kind == "org", !profile.company.isEmpty { return FormStep(field: field, source: .profile("company"), value: profile.company) }
            if field.kind == "city", field.tag != "select", profileKey(field) == "location", !profile.location.isEmpty, !hasAddress {
                return FormStep(field: field, source: .profile("location"), value: profile.location)
            }
            if hasAddress { return FormStep(field: field, source: .wallet) }
            if field.kind == "name" || field.kind == "given" || field.kind == "family", !profile.name.isEmpty {
                let words = profile.name.split(separator: " ").map(String.init)
                let v = field.kind == "given" ? words.first ?? "" : field.kind == "family" ? words.dropFirst().joined(separator: " ") : profile.name
                if !v.isEmpty { return FormStep(field: field, source: .profile("name"), value: v) }
            }
            return FormStep(field: field, source: .yours("none"))
        }
        // Said before, word for word, on this site.
        if let said = answers.answer(to: field.label, site: site), fits(said, field) {
            return FormStep(field: field, source: .answer(said), value: pick(said, field))
        }
        let key = profileKey(field) ?? known[FormAnswers.normal(field.label)].flatMap { Profile.keys.contains($0) && !excluded($0, field) ? $0 : nil }
        if let key, !(key == "bio" && field.tag == "select") {
            // A box that wants more than a line gets the paragraph.
            let wanted = key == "bio" && field.tag == "textarea" && !profile.about.isEmpty ? "about" : key
            if let v = profile.value(wanted, shape: field), fits(v, field) {
                return FormStep(field: field, source: .profile(wanted), value: pick(v, field))
            }
            if key == "bio" || key == "working", field.tag == "textarea" || field.asks { return FormStep(field: field, source: .draft) }
            // Pronouns only as you gave them: otherwise the box is yours.
            return FormStep(field: field, source: .yours(key == "pronouns" ? "self" : "none"))
        }
        if field.tag == "select" || field.type == "radio" { return FormStep(field: field, source: .yours("choice")) }
        let guessed = known[FormAnswers.normal(field.label)]
        // The model's "none" never turns a question into nobody's box.
        if guessed == "none", !field.asks { return FormStep(field: field, source: .yours("none")) }
        if guessed == "question", !field.label.isEmpty { return FormStep(field: field, source: .draft) }
        if field.asks, !field.label.isEmpty { return FormStep(field: field, source: .draft) }
        return FormStep(field: field, source: .yours("none"))
    }

    /// A value a box can take: a menu's or a radio's only if it is one of
    /// its choices, and nothing longer than the box allows.
    static func fits(_ value: String, _ field: FormField) -> Bool {
        if field.tag == "select" || field.type == "radio" { return option(value, in: field.options) != nil }
        if field.maxLength > 0, value.count > field.maxLength { return false }
        return !value.isEmpty
    }

    static func pick(_ value: String, _ field: FormField) -> String {
        if field.tag == "select" || field.type == "radio" { return option(value, in: field.options) ?? value }
        return value
    }

    static func option(_ value: String, in options: [String]) -> String? {
        let want = FormAnswers.normal(value)
        return options.first { FormAnswers.normal($0) == want }
            ?? options.first { !FormAnswers.normal($0).isEmpty && FormAnswers.normal($0).hasPrefix(want) && want.count >= 3 }
    }
}
