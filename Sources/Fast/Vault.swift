import YabStore
import AppKit
import Security
import LocalAuthentication
import CryptoKit
import os

// Where passwords live: the macOS keychain, under this app's own name, as
// internet passwords keyed by site and account. Nothing is written to disk by
// this app in any other form, and nothing is ever logged.
//
// This is the same coffer Safari's are in, but not the same drawer: Apple keeps
// Safari's behind an entitlement no other browser gets. So these are yab's
// in the system's vault, unlocked with the Mac, shown with Touch ID.

struct Login: Identifiable, Equatable, Hashable {
    var host: String
    var user: String
    var password: String
    /// When it was last used to sign in, if known. Newest first in lists.
    var used: Date?
    /// Kept from a page sent in the clear, over plain http. Only these are
    /// offered on such a page: one kept from https, or from before this was
    /// written down, is never handed to a page anyone on the way could have
    /// written.
    var clear = false
    /// The Space it was saved in (Vault.spaceKey). Nil for one saved before
    /// logins knew their Space, brought in from another browser or a file,
    /// or saved somewhere that is no Space's: shared by every Space.
    var space: UUID? = nil

    var id: String { host + "\u{1}" + user }
}

enum Vault {
    /// What every item of ours is tagged with. A test run tags its own, so a
    /// password saved while trying something never sits among the real ones.
    private static let label = Store.name
    /// The security domain this app's items carry: its name and its bundle
    /// id. The name alone was shared by every yab that has been, and an
    /// item another one left, under another bundle id, is not ours to read:
    /// macOS asks for the keychain password for each, a window per login.
    private static let domain = Bundle.main.bundleIdentifier.map { "\(label) · \($0)" } ?? label

    /// What makes an item ours, in every query. The label alone is not enough:
    /// it is not part of an internet password's identity, so a query by site
    /// and account also reaches items another app made for the same pair,
    /// and each of those is a keychain prompt, or a thread held until one is
    /// answered. The security domain is part of the identity, so ours are a
    /// separate set. Items another build of the app left under another bundle
    /// id are never touched: reading them is a prompt per item.
    private static var mine: [String: Any] {
        [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrSecurityDomain as String: domain,
            kSecAttrLabel as String: label,
        ]
    }

    /// The Space a login was saved in rides in the item's description, as
    /// its UUID: not part of an internet password's identity, so tagging
    /// one never makes a second item, and older Yabs read past it. An item
    /// without one, from before this, is shared by every Space; none is
    /// ever rewritten to get one.
    static let spaceKey = kSecAttrDescription as String

    static func space(of row: [String: Any]) -> UUID? {
        (row[spaceKey] as? String).flatMap(UUID.init(uuidString:))
    }

    /// Nothing here ever puts up the keychain's own password window (Keychain).
    static func quietly<T>(_ body: () -> T) -> T { Keychain.quietly(body) }

    /// This app's own logins, cards and addresses kept under an older tag,
    /// moved under its own: the name alone, from before the domain carried
    /// the bundle id, and the name the app kept them under before it was
    /// Yab inside (Store.oldName). Only the ones it can read without asking,
    /// which are the ones it made.
    ///
    /// Started by the browser at launch, off the main thread, and finished
    /// once for good. A write to the login keychain rebuilds its indexes, a
    /// few a second on a keychain that has seen years of use, and this used
    /// to run inside the first keychain read of a launch: in 0.0.13 the
    /// first sign-in a page asked for froze the window for minutes while
    /// every login moved. Each item now takes the keychain on its own, so a
    /// read on the main thread waits for one write at most, and one not
    /// moved yet is missing from lists for the moment instead.
    static func adopt() {
        guard !Store.settings.bool(forKey: adoptedKey) else { return }
        DispatchQueue.global(qos: .utility).async {
            let old = Store.oldName
            let bundle = Bundle.main.bundleIdentifier.map { " · \($0)" } ?? ""
            var finished = true
            for (oldDomain, oldLabel) in [(old + bundle, old), (old, old), (label, label)] where oldDomain != domain {
                finished = carry(
                    [kSecClass as String: kSecClassInternetPassword,
                     kSecAttrSecurityDomain as String: oldDomain, kSecAttrLabel as String: oldLabel],
                    into: [kSecClass as String: kSecClassInternetPassword,
                           kSecAttrSecurityDomain as String: domain, kSecAttrLabel as String: label],
                    keeping: [kSecAttrServer, kSecAttrAccount, kSecAttrComment, kSecAttrDescription]
                ) && finished
            }
            finished = Wallet.adopt() && finished
            if finished { Store.settings.set(true, forKey: adoptedKey) }
        }
    }

    private static let adoptedKey = "passwords.adopted"

    /// Every item matching `old` added again as `fresh` with the attributes
    /// kept and its secret, then the old one deleted. The keychain can't
    /// rename an item's identity in place, and a copy that already exists
    /// counts as done. The keychain is held for one item at a time, never
    /// for the whole move. False when the keychain couldn't be listed, a
    /// locked one, so the move is tried again next launch.
    @discardableResult
    static func carry(_ old: [String: Any], into fresh: [String: Any], keeping: [CFString]) -> Bool {
        var query = old
        query[kSecReturnAttributes as String] = true
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else { return status == errSecItemNotFound }
        let kind = old[kSecClass as String]!
        for row in rows {
            guard let ref = row[kSecValuePersistentRef as String] else { continue }
            quietly {
                var data: CFTypeRef?
                let one: [String: Any] = [
                    kSecClass as String: kind,
                    kSecValuePersistentRef as String: ref,
                    kSecReturnData as String: true,
                ]
                guard Keychain.copyMatching(one as CFDictionary, &data) == errSecSuccess, let secret = data as? Data else { return }
                var item = fresh
                item[kSecValueData as String] = secret
                item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
                for key in keeping {
                    if let value = row[key as String] { item[key as String] = value }
                }
                let added = Keychain.add(item as CFDictionary, nil)
                if added == errSecSuccess || added == errSecDuplicateItem {
                    Keychain.delete([kSecClass as String: kind, kSecValuePersistentRef as String: ref] as CFDictionary)
                }
            }
        }
        return true
    }

    // MARK: - reading

    /// The keychain will list many items, or hand over one secret, not
    /// both in one call. Asked for every item's data at once it answers
    /// errSecParam, and it did so quietly enough that for a while this app
    /// saved passwords it could never read back. So: the list first, without
    /// secrets, then each secret on its own.

    /// What is kept for a host, exactly. See `logins(matching:)` for the
    /// version that also looks across a site's subdomains.
    static func logins(for host: String) -> [Login] {
        rows(where: [kSecAttrServer as String: host]).compactMap(login(from:))
    }

    /// The keychain matches a server name exactly, and a sign-in rarely lives
    /// on the page you saved it from, accounts.example.com asks, and the
    /// password was kept for example.com. So the site is matched as a site:
    /// the host first, then anything sharing its registrable domain.
    static func logins(matching host: String) -> [Login] {
        let domain = registrable(host)
        let exact = logins(for: host)
        let wider = rows(where: [:])
            .filter { ($0[kSecAttrServer as String] as? String).map { $0 != host && registrable($0) == domain } ?? false }
            .compactMap(login(from:))
        return (exact + wider).sorted { ($0.used ?? .distantPast) > ($1.used ?? .distantPast) }
    }

    /// Everything this app holds, for the list. Read on demand and never kept
    /// in a property.
    static func all() -> [Login] {
        rows(where: [:]).compactMap(login(from:))
            .sorted { $0.host == $1.host ? $0.user < $1.user : $0.host < $1.host }
    }

    /// One line a login, with no secret in it: what the passwords page lists
    /// and searches. The list call alone, no per-item read, so a thousand
    /// logins come back at once.
    struct Entry {
        var host: String
        var user: String
        var used: Date?
        var saved: Date?
        var space: UUID? = nil
        var id: String { host + "\u{1}" + user }
    }

    static func entries() -> [Entry] {
        // A login saved before the protocol was recorded and again after it
        // is two keychain items with one id (host and user): one login in
        // the list, with what both know. Two rows of one id leave a blank
        // slot in the passwords list, a row's height of nothing.
        var found: [String: Entry] = [:]
        var order: [String] = []
        for row in rows(where: [:]) {
            guard let host = row[kSecAttrServer as String] as? String,
                  let user = name(of: row)
            else { continue }
            let used = (row[kSecAttrComment as String] as? String)
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            var entry = Entry(host: host, user: user, used: used, saved: row[kSecAttrCreationDate as String] as? Date, space: space(of: row))
            if var first = found[entry.id] {
                first.used = [first.used, entry.used].compactMap { $0 }.max()
                first.saved = [first.saved, entry.saved].compactMap { $0 }.min()
                first.space = first.space ?? entry.space
                entry = first
            } else {
                order.append(entry.id)
            }
            found[entry.id] = entry
        }
        return order.compactMap { found[$0] }
    }

    /// One password, by the two things that name it.
    static func password(host: String, user: String) -> String? {
        secret(host: host, user: user)
    }

    /// What can be said about each password without saying it: a token
    /// that is the same for the same password, so the page can put the
    /// sites that share one together, and whether it is easy to guess.
    /// Every secret is read to know, so it is slow and never on the main
    /// thread. The token is a hash under a salt made fresh each launch: it
    /// matches like with like and tells nothing about what it stands for.
    static func analysis() -> [String: (group: String, weak: Bool)] {
        var out: [String: (group: String, weak: Bool)] = [:]
        for entry in entries() {
            guard let secret = secret(host: entry.host, user: entry.user), !secret.isEmpty else { continue }
            var hash = SHA256()
            hash.update(data: salt)
            hash.update(data: Data(secret.utf8))
            let group = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            out[entry.id] = (group, guessable(secret, user: entry.user, host: entry.host))
        }
        return out
    }

    private static let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })

    /// Easy to guess: short, from a small alphabet, one of the passwords
    /// everyone uses, or made of the name or the site it is for. A rough
    /// measure on purpose, it has to be right about the obvious ones, not
    /// clever about the rest.
    static func guessable(_ password: String, user: String, host: String) -> Bool {
        guard password.count >= 8 else { return true }
        let lowered = password.lowercased()
        if common.contains(lowered) { return true }
        if Set(password).count <= 3 { return true }
        var pool = 0
        if password.contains(where: \.isLowercase) { pool += 26 }
        if password.contains(where: \.isUppercase) { pool += 26 }
        if password.contains(where: \.isNumber) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        if Double(password.count) * log2(Double(max(pool, 2))) < 45 { return true }
        // What the password is for, written into it.
        let name = user.lowercased().split(separator: "@").first.map(String.init) ?? ""
        let site = registrable(host).split(separator: ".").first.map(String.init) ?? ""
        return [name, site].contains { $0.count >= 4 && lowered.contains($0) }
    }

    private static let common: Set<String> = [
        "password", "password1", "password123", "passw0rd", "12345678", "123456789", "1234567890",
        "qwerty123", "qwertyui", "qwertyuiop", "1q2w3e4r", "1q2w3e4r5t", "iloveyou", "11111111",
        "00000000", "abc12345", "abcd1234", "sunshine", "princess", "football", "baseball",
        "welcome1", "letmein1", "admin123", "trustno1", "dragon12", "monkey12", "zaq12wsx",
    ]

    /// The browsers passwords came from, and when they were last taken.
    static var source: (names: [String], at: Date?)? {
        let names = broughtFrom.map(\.name)
        guard !names.isEmpty else { return nil }
        let at = Store.settings.double(forKey: refreshedKey)
        return (names, at > 0 ? Date(timeIntervalSince1970: at) : nil)
    }

    /// The items' attributes, no secrets, narrowed by whatever is given.
    private static func rows(where extra: [String: Any]) -> [[String: Any]] {
        list(where: extra) ?? []
    }

    /// The same, nil when the keychain couldn't be asked, as opposed to
    /// having nothing: a merge that took that for "nothing kept" would
    /// write over everything.
    private static func list(where extra: [String: Any]) -> [[String: Any]]? {
        var query = mine
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        extra.forEach { query[$0] = $1 }
        var out: CFTypeRef?
        let status = quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let rows = out as? [[String: Any]] else {
            // Nothing kept reads as "not found"; anything else is worth a
            // line in the log, because the panel will only say "nothing".
            if status != errSecItemNotFound {
                NSLog("Vault: keychain list failed (%d)", status)
                return nil
            }
            return []
        }
        return rows
    }

    /// The name on an item. A login saved with no name has no account in the
    /// keychain at all, not an empty one, and is still a login.
    private static func name(of row: [String: Any]) -> String? {
        row[kSecAttrAccount as String] as? String ?? ""
    }

    /// What picks out one item. A nameless one can't be asked for by an
    /// empty account, that matches nothing, so it is found among the
    /// site's items and named by its reference instead.
    private static func identity(host: String, user: String) -> [String: Any] {
        let named: [String: Any] = [kSecAttrServer as String: host, kSecAttrAccount as String: user]
        guard user.isEmpty else { return mine.merging(named) { _, new in new } }
        let row = rows(where: [kSecAttrServer as String: host, kSecReturnPersistentRef as String: true])
            .first { $0[kSecAttrAccount as String] == nil }
        guard let ref = row?[kSecValuePersistentRef as String] else { return mine.merging(named) { _, new in new } }
        return [kSecClass as String: kSecClassInternetPassword, kSecValuePersistentRef as String: ref]
    }

    /// One item's secret, by the two things that name it.
    private static func secret(host: String, user: String) -> String? {
        var out: CFTypeRef?
        let query = identity(host: host, user: user).merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        let status = quietly { Keychain.copyMatching(query as CFDictionary, &out) }
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound, status != errSecInteractionNotAllowed { NSLog("Vault: keychain read failed (%d)", status) }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func login(from row: [String: Any]) -> Login? {
        guard let host = row[kSecAttrServer as String] as? String,
              let user = name(of: row),
              let password = secret(host: host, user: user)
        else { return nil }
        // The keychain has no "last used" of its own; it rides in the comment.
        let used = (row[kSecAttrComment as String] as? String)
            .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        let clear = (row[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String)
        return Login(host: host, user: user, password: password, used: used, clear: clear, space: space(of: row))
    }

    // MARK: - writing

    /// Edit a kept password without rewriting its protocol, Space, dates or
    /// identity. A missing item stays missing; this is deliberately not save's
    /// upsert. Resolve one app-owned item by attributes alone, also for a
    /// nameless login; a broad host/account update could change both HTTP and
    /// HTTPS items when two were kept with the same name.
    @discardableResult
    static func replacePassword(host: String, user: String, password: String) -> Bool {
        replacePassword(host: host, user: user, password: password) { host, user, fields in
            guard let owned = list(where: [kSecAttrServer as String: host, kSecReturnPersistentRef as String: true]),
                  let ref = replacementReference(host: host, user: user, owned: owned) else { return errSecItemNotFound }
            let item: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                       kSecValuePersistentRef as String: ref]
            return quietly { Keychain.update(item as CFDictionary, fields as CFDictionary) }
        }
    }

    enum LoginEdit: Equatable { case saved, taken, failed }

    /// The site as typed in the editor: a bare host, lowercased. A pasted
    /// address keeps only its host. Nil when nothing usable is left.
    static func cleanHost(_ text: String) -> String? {
        var site = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if site.contains("://"), let host = URL(string: site)?.host { site = host }
        site = site.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !site.isEmpty, !site.contains(where: \.isWhitespace), !site.contains("/") else { return nil }
        return site
    }

    /// Change the site, the name and/or the password of one kept login in
    /// place: the same keychain item, so its protocol, Space, dates and
    /// last-used stay. `password` nil keeps the secret. A login that would
    /// land on one already kept is refused, and a missing one stays missing.
    static func updateLogin(host: String, user: String, newHost: String, newUser: String,
                            password: String?) -> LoginEdit {
        guard newHost != host || newUser != user else {
            guard let password else { return .failed }
            return replacePassword(host: host, user: user, password: password) ? .saved : .failed
        }
        let edit = updateLogin(host: host, user: user, newHost: newHost, newUser: newUser, password: password,
                               taken: { site, who in
            (list(where: [kSecAttrServer as String: site]) ?? []).contains { name(of: $0) == who }
        }, update: { fields in
            guard let owned = list(where: [kSecAttrServer as String: host, kSecReturnPersistentRef as String: true]),
                  let ref = replacementReference(host: host, user: user, owned: owned) else { return errSecItemNotFound }
            let item: [String: Any] = [kSecClass as String: kSecClassInternetPassword,
                                       kSecValuePersistentRef as String: ref]
            return quietly { Keychain.update(item as CFDictionary, fields as CFDictionary) }
        })
        if edit == .saved {
            // The two-factor key is named by the same pair; it follows.
            if OneTime.move(host: host, user: user, toHost: newHost, toUser: newUser) {
                bump("code/" + host + "\u{1}" + user)
                bump("code/" + newHost + "\u{1}" + newUser)
            }
        }
        return edit
    }

    /// The storage boundary of a rename, with the keychain behind closures.
    static func updateLogin(host: String, user: String, newHost: String, newUser: String, password: String?,
                            taken: (String, String) -> Bool, update: ([String: Any]) -> OSStatus) -> LoginEdit {
        guard !host.isEmpty, !newHost.isEmpty, password?.isEmpty != true else { return .failed }
        guard !taken(newHost, newUser) else { return .taken }
        var fields: [String: Any] = [kSecAttrServer as String: newHost, kSecAttrAccount as String: newUser]
        if let password {
            guard let data = password.data(using: .utf8) else { return .failed }
            fields[kSecValueData as String] = data
        }
        let before = changed.withLock { $0.writes["login/" + newHost + "\u{1}" + newUser] ?? 0 }
        let status = update(fields)
        if status == errSecDuplicateItem { return .taken }
        guard status == errSecSuccess else { return .failed }
        // Sync sees the old name go and the new one arrive.
        bump("login/" + host + "\u{1}" + user)
        bump("login/" + newHost + "\u{1}" + newUser, since: before)
        return .saved
    }

    /// These rows come from `list`'s own-label/domain query, never another
    /// app's items. Refuse ambiguity instead of replacing several secrets.
    static func replacementReference(host: String, user: String, owned rows: [[String: Any]]) -> Data? {
        let matches = rows.filter { ($0[kSecAttrServer as String] as? String) == host && name(of: $0) == user }
        guard matches.count == 1 else { return nil }
        return matches[0][kSecValuePersistentRef as String] as? Data
    }

    /// The storage boundary, also exercised with an in-memory writer. Only the
    /// secret goes through it; neither failure nor empty input marks sync dirty.
    @discardableResult
    static func replacePassword(host: String, user: String, password: String,
                                update: (String, String, [String: Any]) -> OSStatus) -> Bool {
        guard !host.isEmpty, !password.isEmpty, let data = password.data(using: .utf8) else { return false }
        return writing("login/" + host + "\u{1}" + user) {
            update(host, user, [kSecValueData as String: data]) == errSecSuccess
        }
    }

    /// `record`: the wall stamp of the sync record it is written from
    /// (SyncWallet.write), nil for a change made here. `space`: the Space
    /// it was saved in, written on a new item only: a login kept in one
    /// Space and signed in to from another stays the first one's, and one
    /// shared from before stays shared. A record from another Mac carries
    /// its Space onto an item that is here already, too.
    @discardableResult
    static func save(host: String, user: String, password: String, used: Date? = nil, clear: Bool = false,
                     space: UUID? = nil, from record: Int64? = nil) -> Bool {
        guard !host.isEmpty, !password.isEmpty,
              let data = password.data(using: .utf8)
        else { return false }

        let item = identity(host: host, user: user)
        let fields = written(data, used: used, clear: clear, space: space, synced: record != nil)

        return writing("login/" + host + "\u{1}" + user, from: record) { () -> Bool in
            let status = quietly { Keychain.update(item as CFDictionary, fields.update as CFDictionary) }
            if status == errSecSuccess { return true }
            guard status == errSecItemNotFound else { return false }

            var fresh = item.merging(fields.add) { _, new in new }
            fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            return quietly { Keychain.add(fresh as CFDictionary, nil) } == errSecSuccess
        }
    }

    /// What a save writes over an item already kept, and on a new one.
    /// Whether it was kept from plain http rides with it, written on every
    /// save: one from before this reads as https until it is next used on
    /// an http page, a router's, and is marked then. The Space goes on a
    /// new item, and on one here already only from a sync record.
    static func written(_ data: Data, used: Date?, clear: Bool, space: UUID?, synced: Bool) -> (update: [String: Any], add: [String: Any]) {
        var fields: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrProtocol as String: clear ? kSecAttrProtocolHTTP : kSecAttrProtocolHTTPS,
        ]
        if let used { fields[kSecAttrComment as String] = String(used.timeIntervalSince1970) }
        var add = fields
        if let space {
            add[spaceKey] = space.uuidString
            if synced { fields[spaceKey] = space.uuidString }
        }
        return (fields, add)
    }

    /// Another browser's logins, and the sites it was told never to ask about.
    /// A keychain call or two a login, so hundreds of them are seconds: never
    /// on the main thread. Returns how many were kept.
    ///
    /// A write to the login keychain is the slow part, it rebuilds the
    /// file's indexes each time, a few a second on a keychain that has seen
    /// years of use, so only what is new or changed is written. Taking the
    /// same browser again is then reads, which is what makes doing it quietly
    /// at launch affordable. `progress` hears (done, of) now and then.
    ///
    /// A password kept here is never put back to an older one: the other
    /// browser's is written over it only when it was used there more
    /// recently than here (see `replaces`). Changed in yab last week and
    /// still the old one in Chrome, it stays the new one; and the quiet
    /// refresh after launch can't undo a password saved since.
    static func take(_ found: Chromium.Found, progress: ((Int, Int) -> Void)? = nil) -> Int {
        // Each login here and when it was last used, from the list call:
        // no secret is read for one the other browser can't replace.
        guard let listed = list(where: [:]) else { return 0 }
        var have: [String: Date?] = [:]
        for row in listed {
            guard let host = row[kSecAttrServer as String] as? String,
                  let user = name(of: row)
            else { continue }
            have[host + "\u{1}" + user] = (row[kSecAttrComment as String] as? String)
                .flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        }
        var kept = 0
        let total = found.logins.count
        for (index, login) in found.logins.enumerated() {
            if index % 10 == 0 { progress?(index, total) }
            if let ours = have[login.id] {
                guard replaces(theirs: login.used, ours: ours) else { continue }
                if secret(host: login.host, user: login.user) == login.password { continue }
            }
            if save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
                kept += 1
            }
        }
        progress?(total, total)
        var never = never
        found.never.forEach { never.insert($0) }
        self.never = never
        return kept
    }

    /// Whether another browser's password goes over the one kept here for
    /// the same site and name: only when it was used there after it was
    /// last used here. One the other browser never used says nothing about
    /// being newer, and loses; one here that was never used, kept from an
    /// earlier import, loses to any that was.
    static func replaces(theirs: Date?, ours: Date?) -> Bool {
        guard let theirs else { return false }
        guard let ours else { return true }
        return theirs > ours
    }

    /// Every browser passwords were ever brought in from, at onboarding or
    /// since, taken again without asking: a login saved there since then is
    /// here too, and a sign-in never comes up empty just because the import
    /// was a while ago. Only where macOS hands over the browser's key without
    /// a prompt, it does once you have said "Always Allow", and at most
    /// every few hours.
    static func refresh() {
        // Only what the settings say, here: which browsers are still
        // installed is a walk of their folders, 18 ms on the main thread
        // at launch, before the window's first frame, and waits with the
        // rest.
        guard !(Store.settings.stringArray(forKey: fromAllKey) ?? []).isEmpty || Store.settings.string(forKey: fromKey) != nil else { return }
        let last = Store.settings.double(forKey: refreshedKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        // After launch has settled; nothing waits on this.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) {
            for source in broughtFrom {
                guard let found = try? Chromium.read(source, quiet: true) else { continue }
                let kept = take(found)
                if kept > 0 { NSLog("Vault: %d new or changed from %@", kept, source.name) }
            }
            Store.settings.set(Date().timeIntervalSince1970, forKey: refreshedKey)
        }
    }

    /// Which browsers those are, each added by the import that worked.
    static func broughtIn(from source: Chromium.Source) {
        var names = Store.settings.stringArray(forKey: fromAllKey) ?? []
        names.removeAll { $0 == source.name }
        names.insert(source.name, at: 0)
        Store.settings.set(names, forKey: fromAllKey)
        Store.settings.set(source.name, forKey: fromKey)
        Store.settings.set(Date().timeIntervalSince1970, forKey: refreshedKey)
    }

    /// The browsers passwords came from that are still on this Mac, most
    /// recent first. From before the list was kept, the one name there was.
    static var broughtFrom: [Chromium.Source] {
        var names = Store.settings.stringArray(forKey: fromAllKey) ?? []
        if let one = Store.settings.string(forKey: fromKey), !names.contains(one) { names.append(one) }
        let installed = Chromium.installed()
        return names.compactMap { name in installed.first { $0.name == name } }
    }

    private static let fromKey = "passwords.from"
    private static let fromAllKey = "passwords.fromAll"
    private static let refreshedKey = "passwords.refreshed"

    /// It was just used to sign in. Lists put it first from now on.
    static func touch(_ login: Login) {
        save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear)
    }

    static func forget(host: String, user: String, from record: Int64? = nil) {
        removing("login/" + host + "\u{1}" + user, from: record) {
            _ = quietly { Keychain.delete(identity(host: host, user: user) as CFDictionary) }
        }
    }

    // MARK: - for sync

    /// Bumped at every change to the passwords, two-factor keys, cards and
    /// addresses kept here, with which one changed: sync reads them again
    /// only when this moved, and those named whatever the keychain's date
    /// says, as it keeps whole seconds and a change within the same second
    /// would read as none (SyncWallet).
    static var changes: Int { changed.withLock { $0.count } }
    private static let changed = OSAllocatedUnfairLock(initialState: Changes())
    private struct Changes {
        var count = 0
        var items = Set<String>()
        /// How many writes each item has had, so a write sync made can
        /// tell another came between it and its mark.
        var writes: [String: Int] = [:]
        /// Items as sync last wrote them in, by the wall stamp of the
        /// record each came from (`synced`).
        var synced: [String: Int64] = [:]
        /// Yab knows the fraction of a second for its own edits, even when
        /// the keychain returns only the whole second.
        var local: [String: Date] = [:]
        var unpublished: [String: Int] = [:]
    }

    /// A write to the keychain, marked changed once it is in, never
    /// before: a read of sync's that took the mark between the two read
    /// what the item said before, dated the second before, and a second
    /// change in that second was never read again (the dates are equal).
    /// `record`: the wall stamp of the sync record it is written from,
    /// kept only if the write went in.
    @discardableResult
    static func writing(_ item: String, from record: Int64? = nil, _ write: () -> Bool) -> Bool {
        let before = changed.withLock { $0.writes[item] ?? 0 }
        let written = write()
        if written { bump(item, from: record, since: before) }
        return written
    }

    /// A removal from the keychain, marked once done (`writing`).
    static func removing(_ item: String, from record: Int64? = nil, _ remove: () -> Void) {
        let before = changed.withLock { $0.writes[item] ?? 0 }
        remove()
        bump(item, from: record, since: before)
    }

    /// An item written: `record` when sync wrote it in from that record,
    /// nil for a change made here; `since`, how many writes it had before
    /// this one, so a change made here in between keeps sync's mark off.
    static func bump(_ item: String, from record: Int64? = nil, since: Int? = nil) {
        changed.withLock { state in
            let alone = since == nil || state.writes[item, default: 0] == since
            state.count += 1
            state.items.insert(item)
            state.writes[item, default: 0] += 1
            state.synced[item] = alone ? record : nil
            if alone {
                state.local[item] = record == nil ? Date() : nil
                state.unpublished[item] = record == nil ? state.writes[item] : nil
            }
        }
    }

    /// Items a read of sync's took and then threw away, to be read again.
    static func again(_ item: String) { changed.withLock { $0.count += 1; $0.items.insert(item) } }

    /// The items changed since the last ask, once.
    static func changedItems() -> Set<String> { changed.withLock { state in defer { state.items = [] }; return state.items } }

    /// The wall stamp of the record sync last wrote this item in from,
    /// while nothing here changed it since: its date in the keychain is
    /// when sync wrote it, not when the password changed (SyncWallet).
    static func synced(_ item: String) -> Int64? { changed.withLock { $0.synced[item] } }

    static func modified(_ item: String, fallback: Date?) -> Date? {
        changed.withLock { $0.local[item] ?? fallback }
    }

    static func localChanges() -> [String: Int] { changed.withLock { $0.unpublished } }

    /// Items from before joining settle by their dates. Only edits made
    /// while this account's mirror runs are waiting for its publication.
    static func beginSync() { changed.withLock { $0.unpublished.removeAll() } }

    /// A read reached the journal. An edit made after that read still waits
    /// to be published before any arriving password can replace it.
    static func published(_ items: [String: Int]) {
        changed.withLock { state in
            for (item, generation) in items where state.unpublished[item] == generation {
                state.unpublished[item] = nil
            }
        }
    }

    /// Each login as the list call has it, no secret read: its names, when
    /// it was used and when it last changed. Nil when the keychain couldn't
    /// be asked, which is not the same as nothing kept.
    struct Listed {
        var host: String
        var user: String
        var used: Date?
        var modified: Date?
        var clear: Bool
        var space: UUID? = nil
        var id: String { host + "\u{1}" + user }
    }

    static func listed() -> [Listed]? {
        list(where: [:]).map(listed(from:))
    }

    /// The list call's rows, as Listed.
    static func listed(from rows: [[String: Any]]) -> [Listed] {
        rows.compactMap { row in
            guard let host = row[kSecAttrServer as String] as? String, let user = name(of: row) else { return nil }
            return Listed(host: host, user: user,
                          used: (row[kSecAttrComment as String] as? String).flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),
                          modified: row[kSecAttrModificationDate as String] as? Date,
                          clear: (row[kSecAttrProtocol as String] as? String) == (kSecAttrProtocolHTTP as String),
                          space: space(of: row))
        }
    }

    // MARK: - sites that asked not to be asked

    private static let neverKey = "passwords.never"

    static var never: Set<String> {
        get { Set(Store.settings.stringArray(forKey: neverKey) ?? []) }
        set { Store.settings.set(Array(newValue).sorted(), forKey: neverKey) }
    }

    static func never(_ host: String) { never.insert(host) }
    static func isNever(_ host: String) -> Bool { never.contains(host) || never.contains(registrable(host)) }

    // MARK: - showing one

    /// A password is shown only to the person the Mac belongs to. Touch ID,
    /// the watch, or the account password, whatever the Mac itself takes.
    static func prove(_ reason: String, _ done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // No way to ask at all, a Mac with no password set. Then there is
            // nothing to prove.
            done(true)
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }

    // MARK: - filling one

    /// Settings › Passwords › Ask for Touch ID before filling.
    static let proveKey = "passwords.prove"

    /// What this Mac proves with, as the switch and the note name it:
    /// Touch ID where it has it with a finger enrolled, its password where
    /// it doesn't. Asked each time rather than once a launch: a keyboard
    /// with Touch ID comes and goes, and a finger can be added.
    static var proof: String {
        let context = LAContext()
        let enrolled = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return enrolled && context.biometryType == .touchID ? "Touch ID" : "your Mac's password"
    }

    /// How long one yes to filling lasts. A sign-in in two steps, or a
    /// second site a minute later, isn't asked again; a Mac left alone is,
    /// since locking it, letting it sleep or switching to another user ends
    /// the yes early, as does turning the switch off or on.
    static let grace: TimeInterval = 300
    private static var provenAt: Date?
    /// An agent's sign-in here said yes to on another device of the
    /// person's, with Face ID, Touch ID or its passcode there: that one
    /// fill on that site goes without asking again, for two minutes.
    static var provenElsewhere: (site: String, at: Date)?
    /// Fills waiting on the one question up now: the site each is for, and
    /// whether an agent started it.
    private static var waiting: [(site: String, agent: Bool, done: (Proven) -> Void)] = []
    /// The question up now, for the bench to see and take down.
    private(set) static var asking: LAContext?
    private static var lockWatch: [NSObjectProtocol] = []

    /// Answers whether a kept password may go into a page on `host` now.
    /// Straight away, and without a word, unless Settings asks for Touch ID
    /// and no yes has been given within the grace. A fill an agent started
    /// is asked about every time and its yes lends nothing to the next: the
    /// person is answering for that one sign-in.
    static func proveToFill(on host: String, agent: Bool = false, _ done: @escaping (Proven) -> Void) {
        guard Store.settings.bool(forKey: proveKey) else { done(.yes); return }
        if !agent, let provenAt, Date().timeIntervalSince(provenAt) < grace { done(.yes); return }
        if agent, let elsewhere = provenElsewhere, elsewhere.site == registrable(host), Date().timeIntervalSince(elsewhere.at) < 120 {
            provenElsewhere = nil
            done(.yes)
            return
        }
        waiting.append((registrable(host), agent, done))
        guard waiting.count == 1 else { return }
        ask()
    }

    /// The question, for the first fill waiting; the others that are for
    /// the same site, and started the same way, hear its answer.
    private static func ask() {
        guard let first = waiting.first else { return }
        watchForLock()
        let context = LAContext()
        var trouble: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &trouble) else {
            // A Mac with no password set has nothing to prove, as with
            // showing one; anything else that stops the question is a no
            // nobody said, which whoever waits should say something about.
            answer(trouble?.code == LAError.passcodeNotSet.rawValue ? .yes : .cannot, for: first)
            return
        }
        asking = context
        let site = first.site.isEmpty ? "this page" : first.site
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "fill your password on \(site)") { ok, _ in
            DispatchQueue.main.async { answer(ok ? .yes : .no, for: first) }
        }
    }

    /// How a question to fill went: given, turned down (or taken down
    /// unanswered), or never put, the Mac unable to ask.
    enum Proven { case yes, no, cannot }

    private static func answer(_ ok: Proven, for first: (site: String, agent: Bool, done: (Proven) -> Void)) {
        asking = nil
        if ok == .yes, !first.agent { provenAt = Date() }
        let heard = waiting.filter { $0.site == first.site && $0.agent == first.agent }
        let rest = waiting.filter { !($0.site == first.site && $0.agent == first.agent) }
        waiting = []
        heard.forEach { $0.done(ok) }
        // The others were never asked about: each asks again, and one a
        // person started may find the yes just given still good.
        for other in rest { proveToFill(on: other.site, agent: other.agent, other.done) }
    }

    /// A yes lasts only while the Mac is in the hands that gave it.
    private static func watchForLock() {
        guard lockWatch.isEmpty else { return }
        let forget: (Notification) -> Void = { _ in provenAt = nil }
        let workspace = NSWorkspace.shared.notificationCenter
        lockWatch = [
            DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: forget),
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: forget),
        ]
    }

    /// Forget the last yes: the switch was turned, or the bench asks. With
    /// `cancelling`, a question that is up is taken down unanswered, as
    /// Cancel would.
    static func forgetProof(cancelling: Bool) {
        provenAt = nil
        if cancelling { asking?.invalidate() }
    }

    // MARK: - the site behind a host

    /// example.com for www.example.com and accounts.example.com; bbc.co.uk
    /// stays bbc.co.uk; a.github.io and b.github.io are two.
    static func registrable(_ host: String) -> String {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let labels = name.split(separator: ".").map(String.init)
        // An address, not a name: all of it is the site.
        if name.contains(":") || labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return name }
        guard labels.count > 1 else { return name }
        // The list of public suffixes macOS keeps, the one Safari reads: a
        // site is the name one label longer than the longest suffix it ends
        // in. So a.github.io and b.github.io are two sites, and
        // accounts.google.com is still google.com.
        if let isSuffix = publicSuffix {
            if isSuffix(name as CFString) { return name }
            for count in stride(from: labels.count - 1, through: 1, by: -1)
            where isSuffix(labels.suffix(count).joined(separator: ".") as CFString) {
                return labels.suffix(count + 1).joined(separator: ".")
            }
            return name
        }
        // Without it, a guess: the last two labels, three under a country's
        // own second level.
        guard labels.count > 2 else { return name }
        let seconds: Set<String> = ["co", "com", "org", "net", "gov", "gouv", "ac", "edu", "asso", "or", "ne"]
        if seconds.contains(labels[labels.count - 2]), labels[labels.count - 1].count == 2 {
            return labels.suffix(3).joined(separator: ".")
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// WebKit's own test for a public suffix, from the list macOS keeps.
    /// Private to CFNetwork, and looked up rather than linked, so a macOS
    /// without it falls back to the guess above.
    nonisolated static let publicSuffix: (@convention(c) (CFString) -> Bool)? = {
        guard let symbol = dlsym(dlopen("/System/Library/Frameworks/CFNetwork.framework/CFNetwork", RTLD_NOW),
                                 "_CFHostIsDomainTopLevel")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CFString) -> Bool).self)
    }()

    static func host(of text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        if !value.contains("://") { value = "https://" + value }
        guard let host = URL(string: value)?.host()?.lowercased() else { return "" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: - taking in an export

    /// A CSV as Google Password Manager, Chrome or Dia write it (name, url,
    /// username, password, note) or Zen and Firefox do (url, username,
    /// password, httpRealm, and so on). Read once, put in the keychain, and the file
    /// is yours to delete, this never keeps a copy of it. A file someone
    /// chose is taken at its word, over what is kept here; a password it
    /// changes is marked used now, so taking a browser again later can't
    /// put back the older one (see `replaces`). A keychain call or two a
    /// row: never on the main thread.
    static func take(csv text: String) -> (kept: Int, changed: Int, skipped: Int) {
        let found = logins(csv: text)
        var kept = 0, changed = 0, skipped = found.skipped
        for login in found.logins {
            let before = secret(host: login.host, user: login.user)
            // Its two-factor key, which Safari, 1Password, Bitwarden and the
            // rest write beside the password: codes come from Yab too.
            if let code = found.codes[login.host + "\u{1}" + login.user], OneTime.text(host: login.host, user: login.user) != code {
                OneTime.save(code, host: login.host, user: login.user)
            }
            if before == login.password {
                kept += 1
                continue
            }
            let used: Date? = before == nil ? nil : Date()
            guard save(host: login.host, user: login.user, password: login.password, used: used, clear: login.clear) else {
                skipped += 1
                continue
            }
            kept += 1
            if before != nil { changed += 1 }
        }
        return (kept, changed, skipped)
    }

    /// The logins in such a CSV, and how many rows weren't one. `codes`: a
    /// login's two-factor key where the file has one (an otpauth:// link or
    /// the key alone), by host and user.
    static func logins(csv text: String) -> (logins: [Login], skipped: Int, codes: [String: String]) {
        var rows = Csv.rows(text)
        guard !rows.isEmpty else { return ([], 0, [:]) }

        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func column(_ names: [String]) -> Int? {
            header.firstIndex { names.contains($0) }
        }
        guard let urlAt = column(["url", "login_uri", "website", "site"]),
              let userAt = column(["username", "login_username", "user", "email"]),
              let passAt = column(["password", "login_password"])
        else { return ([], rows.count, [:]) }
        let codeAt = column(["otpauth", "login_totp", "totp", "otpsecret", "otp"])
        // Proton Pass writes both an email and a username, often only one
        // of them filled: the other is the name when the first is empty.
        let otherUsers = header.indices.filter { $0 != userAt && ["username", "login_username", "user", "email"].contains(header[$0]) }

        var out: [Login] = []
        var codes: [String: String] = [:]
        var skipped = 0
        for row in rows {
            guard row.count > max(urlAt, max(userAt, passAt)) else {
                skipped += 1
                continue
            }
            let host = self.host(of: row[urlAt])
            let password = row[passAt]
            // Firefox's export also lists its own account, at
            // chrome://FirefoxAccounts: only a site's sign-in comes.
            let address = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased()
            let web = !address.contains("://") || address.hasPrefix("http://") || address.hasPrefix("https://")
            guard web, !host.isEmpty, !password.isEmpty else {
                skipped += 1
                continue
            }
            let clear = row[urlAt].trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
            var user = row[userAt]
            if user.isEmpty, let other = otherUsers.first(where: { row.count > $0 && !row[$0].isEmpty }) { user = row[other] }
            out.append(Login(host: host, user: user, password: password, clear: clear))
            if let codeAt, row.count > codeAt {
                let code = row[codeAt].trimmingCharacters(in: .whitespacesAndNewlines)
                if !code.isEmpty, OneTime.parse(code) != nil { codes[host + "\u{1}" + user] = code }
            }
        }
        return (out, skipped, codes)
    }
}
