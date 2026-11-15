import Contacts
import Foundation
import SQLite3

// Cards and addresses from where they already are: another browser on this
// Mac, and your own card in Contacts.
//
// A Chromium browser keeps them in its "Web Data", a SQLite file beside
// "Login Data" in each profile. A card's number is wrapped the way a
// password is, with the same key from the same keychain item (Import.swift),
// so a browser whose passwords were brought in gives its cards without
// asking again. Cards kept only on Google's servers (masked_credit_cards)
// have no number here and are left. A card's security code, when the
// browser keeps it, is in `local_stored_cvc` by the card's guid. Addresses are in one of three shapes,
// newest first: `addresses` with its type tokens, `local_addresses` with
// its, or the old `autofill_profiles` and the tables beside it.

extension Chromium {
    struct Kept {
        var cards: [SavedCard] = []
        var addresses: [StreetAddress] = []
    }

    /// Every profile's Web Data.
    static func webData(_ source: Source) -> [URL] {
        guard source.credentialAccess else { return [] }
        return source.profiles
            .map { $0.appendingPathComponent("Web Data") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// How many there are to bring, without the keychain: rows counted,
    /// not unwrapped.
    static func walletCount(_ source: Source) -> (cards: Int, addresses: Int) {
        var cards = 0, addresses = 0
        for file in webData(source) {
            guard let temp = try? copyWithLog(file) else { continue }
            defer { removeWithLog(temp) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            cards += count(db, "SELECT COUNT(*) FROM credit_cards WHERE length(card_number_encrypted) > 0")
            addresses += count(db, "SELECT COUNT(*) FROM addresses") + count(db, "SELECT COUNT(*) FROM local_addresses")
                + count(db, "SELECT COUNT(*) FROM autofill_profiles")
        }
        return (cards, addresses)
    }

    /// Everything, unwrapped. `quiet`: fail rather than ask for the key.
    static func wallet(_ source: Source, quiet: Bool = false) throws -> Kept {
        var out = Kept()
        let files = webData(source)
        guard !files.isEmpty else { return out }
        var key: [UInt8]?
        for file in files {
            let temp = try copyWithLog(file)
            defer { removeWithLog(temp) }
            var db: OpaquePointer?
            guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            if count(db, "SELECT COUNT(*) FROM credit_cards WHERE length(card_number_encrypted) > 0") > 0 {
                if key == nil {
                    guard let passphrase = safeStorage(source, quiet: quiet) else { throw Trouble.noPassphrase }
                    key = stretch(passphrase)
                }
                out.cards += cards(db, key: key ?? [], from: source.name)
            }
            out.addresses += addresses(db, from: source.name)
        }
        return out
    }

    /// One Web Data file, read with a key already stretched: what `wallet`
    /// does for each profile, and what a test run hands a file of its own.
    static func wallet(file: URL, key: [UInt8], from source: String) throws -> Kept {
        let temp = try copyWithLog(file)
        defer { removeWithLog(temp) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else { throw Trouble.unreadable }
        defer { sqlite3_close(db) }
        return Kept(cards: cards(db, key: key, from: source), addresses: addresses(db, from: source))
    }

    // MARK: - cards

    private static func cards(_ db: OpaquePointer, key: [UInt8], from source: String) -> [SavedCard] {
        // Security codes, where the browser was let keep them: a table of
        // their own by the card's guid, wrapped with the same key.
        var codes: [String: String] = [:]
        _ = rows(db, "SELECT guid, value_encrypted FROM local_stored_cvc") { row -> Int? in
            guard let blob = row.blob(1), let plain = unwrap(blob, key: key) else { return nil }
            let code = plain.filter(\.isNumber)
            if (3...4).contains(code.count) { codes[row.text(0)] = code }
            return nil
        }
        let columns = columns(in: db, table: "credit_cards")
        let sql = "SELECT name_on_card, expiration_month, expiration_year, card_number_encrypted, "
            + (columns.contains("use_date") ? "use_date" : "0") + ", "
            + (columns.contains("nickname") ? "COALESCE(nickname, '')" : "''") + ", guid FROM credit_cards"
        return rows(db, sql) { row in
            guard let blob = row.blob(3), let plain = unwrap(blob, key: key) else { return nil }
            var digits = plain.filter(\.isNumber)
            // A build that puts a hash of the site before the value, as for
            // passwords: past it, the number.
            if !(12...19).contains(digits.count) || !Fast.Wallet.luhn(digits), plain.utf8.count > 32 {
                digits = String(decoding: Array(plain.utf8).dropFirst(32), as: UTF8.self).filter(\.isNumber)
            }
            guard Fast.Wallet.luhn(digits) else { return nil }
            let used = row.int(4)
            return SavedCard(
                id: UUID().uuidString, number: digits, last4: String(digits.suffix(4)), brand: Fast.Wallet.brand(of: digits),
                name: row.text(0), month: row.int(1), year: Fast.Wallet.fullYear(row.int(2)),
                used: used > 0 ? Date(timeIntervalSince1970: TimeInterval(used)) : nil, saved: nil,
                nickname: row.text(5), source: source, csc: codes[row.text(6)] ?? ""
            )
        }
    }

    // MARK: - addresses

    /// Chromium's own numbers for the parts of an address (FieldType).
    private enum Part: Int {
        case first = 3, last = 5, full = 7, email = 9, phone = 14
        case line1 = 30, line2 = 31, city = 33, state = 34, zip = 35, country = 36
        case company = 60, street = 77, line3 = 78
    }

    private static func addresses(_ db: OpaquePointer, from source: String) -> [StreetAddress] {
        var found: [StreetAddress] = []
        for (table, tokens) in [("addresses", "address_type_tokens"), ("local_addresses", "local_addresses_type_tokens")]
        where count(db, "SELECT COUNT(*) FROM \(table)") > 0 {
            var parts: [String: [Part: String]] = [:]
            var used: [String: Int] = [:]
            _ = rows(db, "SELECT guid, use_date FROM \(table)") { row -> Int? in
                used[row.text(0)] = row.int(1)
                return nil
            }
            _ = rows(db, "SELECT guid, type, value FROM \(tokens)") { row -> Int? in
                if let part = Part(rawValue: row.int(1)), !row.text(2).isEmpty { parts[row.text(0), default: [:]][part] = row.text(2) }
                return nil
            }
            found += parts.keys.sorted().compactMap { guid in
                place(parts[guid] ?? [:], used: used[guid] ?? 0, from: source)
            }
        }
        // The old shape: a profile, with its names, emails and phones apart.
        var parts: [String: [Part: String]] = [:]
        var used: [String: Int] = [:]
        _ = rows(db, "SELECT guid, company_name, street_address, city, state, zipcode, country_code, use_date FROM autofill_profiles") { row -> Int? in
            let guid = row.text(0)
            parts[guid] = [.company: row.text(1), .street: row.text(2), .city: row.text(3), .state: row.text(4),
                           .zip: row.text(5), .country: row.text(6)]
            used[guid] = row.int(7)
            return nil
        }
        _ = rows(db, "SELECT guid, first_name, last_name, full_name FROM autofill_profile_names") { row -> Int? in
            parts[row.text(0)]?[.first] = row.text(1)
            parts[row.text(0)]?[.last] = row.text(2)
            parts[row.text(0)]?[.full] = row.text(3)
            return nil
        }
        _ = rows(db, "SELECT guid, email FROM autofill_profile_emails") { row -> Int? in
            parts[row.text(0)]?[.email] = row.text(1)
            return nil
        }
        _ = rows(db, "SELECT guid, number FROM autofill_profile_phones") { row -> Int? in
            parts[row.text(0)]?[.phone] = row.text(1)
            return nil
        }
        found += parts.keys.sorted().compactMap { guid in place(parts[guid] ?? [:], used: used[guid] ?? 0, from: source) }
        return found
    }

    private static func place(_ part: [Part: String], used: Int, from source: String) -> StreetAddress? {
        func it(_ p: Part) -> String { (part[p] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        var address = StreetAddress(id: UUID().uuidString)
        address.name = !it(.full).isEmpty ? it(.full) : [it(.first), it(.last)].filter { !$0.isEmpty }.joined(separator: " ")
        address.organization = it(.company)
        address.street = !it(.street).isEmpty ? it(.street) : [it(.line1), it(.line2), it(.line3)].filter { !$0.isEmpty }.joined(separator: "\n")
        address.city = it(.city)
        address.region = it(.state)
        address.postal = it(.zip)
        address.country = it(.country)
        address.phone = it(.phone)
        address.email = it(.email)
        address.used = used > 0 ? Date(timeIntervalSince1970: TimeInterval(used)) : nil
        address.source = source
        return address.whole ? address : nil
    }

    // MARK: - the file

    private struct Row {
        let statement: OpaquePointer
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(statement, i)) }
        func blob(_ i: Int32) -> Data? {
            guard let bytes = sqlite3_column_blob(statement, i) else { return nil }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, i)))
        }
    }

    /// Each row made into something, or skipped; a table that isn't there
    /// is no rows.
    private static func rows<T>(_ db: OpaquePointer, _ sql: String, _ make: (Row) -> T?) -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let made = make(Row(statement: statement)) { out.append(made) }
        }
        return out
    }

    private static func count(_ db: OpaquePointer, _ sql: String) -> Int {
        rows(db, sql) { $0.int(0) }.first ?? 0
    }
}

// MARK: - your card in Contacts

enum MeCard {
    /// The addresses on your own card in Contacts, the one marked as you,
    /// with its name, email and phone. Asks for Contacts the first time.
    static func addresses(_ done: @escaping ([StreetAddress]) -> Void) {
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, _ in
            guard ok else { return DispatchQueue.main.async { done([]) } }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                        CNContactPostalAddressesKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
            guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return DispatchQueue.main.async { done([]) } }
            let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let found = me.postalAddresses.map { labeled -> StreetAddress in
                let postal = labeled.value
                var address = StreetAddress(id: UUID().uuidString)
                address.name = name
                address.organization = me.organizationName
                address.street = postal.street
                address.city = postal.city
                address.region = postal.state
                address.postal = postal.postalCode
                address.country = postal.isoCountryCode.isEmpty ? postal.country : postal.isoCountryCode.uppercased()
                address.email = me.emailAddresses.first.map { String($0.value) } ?? ""
                address.phone = me.phoneNumbers.first?.value.stringValue ?? ""
                address.source = "Contacts"
                return address
            }.filter(\.whole)
            DispatchQueue.main.async { done(found) }
        }
    }

    /// Your card's facts for the profile (Profile): the name, the company,
    /// the job title, the links and social profiles, where you live. Only
    /// asks for Contacts when `ask`; otherwise nothing without a yes given
    /// before. Hears nil when there is no card.
    static func profile(ask: Bool, _ done: @escaping ([String: String]?) -> Void) {
        guard ask || allowed else { return done(nil) }
        let store = CNContactStore()
        store.requestAccess(for: .contacts) { ok, _ in
            guard ok else { return DispatchQueue.main.async { done(nil) } }
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                        CNContactUrlAddressesKey, CNContactSocialProfilesKey, CNContactPostalAddressesKey] as [CNKeyDescriptor]
            guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return DispatchQueue.main.async { done(nil) } }
            var found: [String: String] = [:]
            let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { found["name"] = name }
            if !me.organizationName.isEmpty { found["company"] = me.organizationName }
            if !me.jobTitle.isEmpty { found["role"] = me.jobTitle }
            for link in me.urlAddresses.map({ String($0.value) }) {
                let key = MeCard.key(for: link)
                if found[key] == nil { found[key] = link }
            }
            for social in me.socialProfiles.map(\.value) {
                let service = social.service.lowercased()
                let handle = social.username.isEmpty ? social.urlString : social.username
                guard !handle.isEmpty else { continue }
                let key = service.contains("twitter") || service == "x" ? "x" : service.contains("linkedin") ? "linkedin"
                    : service.contains("github") ? "github" : service.contains("telegram") ? "telegram"
                    : service.contains("instagram") ? "instagram" : ""
                if !key.isEmpty, found[key] == nil { found[key] = handle }
            }
            if let home = me.postalAddresses.first?.value {
                let place = [home.city, home.country].filter { !$0.isEmpty }.joined(separator: ", ")
                if !place.isEmpty { found["location"] = place }
            }
            DispatchQueue.main.async { done(found.isEmpty ? nil : found) }
        }
    }

    /// Which profile key a link on your card is, by its site.
    static func key(for link: String) -> String {
        let host = (URL(string: link.contains("://") ? link : "https://" + link)?.host() ?? "").lowercased()
        if host.hasSuffix("linkedin.com") { return "linkedin" }
        if host == "x.com" || host.hasSuffix(".x.com") || host.hasSuffix("twitter.com") { return "x" }
        if host.hasSuffix("github.com") { return "github" }
        if host == "t.me" || host.hasSuffix("telegram.me") { return "telegram" }
        if host.hasSuffix("instagram.com") { return "instagram" }
        return "website"
    }

    /// Your card into the profile, where it has something and nobody has
    /// written that key yet. Quiet: no question, no word.
    @MainActor
    static func fillProfile(ask: Bool = false, _ done: ((Int) -> Void)? = nil) {
        let epoch = ContextPrivacy.shared.epoch
        profile(ask: ask) { found in
            guard ContextPrivacy.shared.current(epoch) else { done?(0); return }
            guard let found else { done?(0); return }
            var kept = Profile.load()
            let empty = found.filter { kept[$0.key].isEmpty && !kept.edited.contains($0.key) }
            let changed = kept.merge(empty, source: "contact card").changed
            if !changed.isEmpty { Profile.save(kept, origin: .manual(Set(changed))) }
            done?(changed.count)
        }
    }

    /// The numbers on your card, each with its label ("mobile"), only when
    /// Contacts said yes before: a phone box is never a reason to ask.
    /// Off the main thread; heard there too.
    nonisolated static func phones() -> [(number: String, label: String)] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized,
              let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: [CNContactPhoneNumbersKey] as [CNKeyDescriptor])
        else { return [] }
        return me.phoneNumbers.map { labeled in
            (labeled.value.stringValue, labeled.label.map { CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0) } ?? "")
        }
    }

    /// Whether Contacts has said yes before, so the page can offer your
    /// card without the question coming first.
    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }
}
