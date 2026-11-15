import AppKit
import Security
import SwiftUI

/// The list under a sign-in box: Yab's own logins and, only where it costs
/// the person nothing more, a manager Yab reads itself (ManagerVaults:
/// 1Password with its app's CLI integration already on, Bitwarden's `bw`
/// already signed in on this Mac). Any other manager keeps its own menu;
/// its entries as rows (ManagerMenus) and "Fill with <Manager>" are drawn
/// only for staged states. Rows are grouped by
/// source with a line between groups, the manager's icon cut into the
/// corner of the site's mark, the source in words under the name
/// (docs/password-manager-vaults.md, the picked design "A").
struct SuggestRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case yab(Login)
        case managed(ManagerVault.Login)
        /// A name the manager's own menu lists; picked, its menu fills.
        case entry(ManagerMenus.Entry)
        /// The manager's menu shows its lock, and nobody is unlocking it.
        case locked(String)
        /// A locked manager Yab is unlocking: its logins come in here.
        case unlocking(String)
        /// Nothing anywhere: where it looked.
        case nothing
        case open(String)
        /// A manager with no API: its own extension fills.
        case hybrid(String, busy: Bool)
        /// A new password; this manager's extension offers to keep it after
        /// the sign-up (nil: Yab's own card).
        case generate(String?, password: String)
        case all
        /// One of your own addresses, for an email box on a site with no
        /// login: the address alone goes in.
        case email(String)
    }

    let kind: Kind
    var group = 0
    var title: String
    var detail: String = ""
    var used: Date? = nil
    /// The one thing to take: ↩ on its right instead of when.
    var quick = false
    /// The manager cut into the corner of the site's mark.
    var badge: String? = nil
    /// The site whose mark it wears.
    var host = ""
    /// The detail is a password to show as it is (monospaced).
    var shown: String? = nil
    /// A quiet well with this glyph instead of a mark.
    var glyph: String? = nil
    /// A login saved in another Space: its emoji and name. Such rows come
    /// last, dimmed, under "Other Spaces".
    var away: String? = nil

    var id: String {
        switch kind {
        case .yab(let login): return "yab/" + login.id
        case .managed(let login): return "m/" + login.id
        case .entry(let entry): return "e/" + entry.provider + "/" + entry.title + "/" + entry.detail
        case .locked(let id): return "locked/" + id
        case .unlocking(let id): return "unlocking/" + id
        case .nothing: return "nothing"
        case .open(let id): return "open/" + id
        case .hybrid(let id, _): return "hybrid/" + id
        case .generate(let id, _): return "generate/" + (id ?? "yab")
        case .all: return "all"
        case .email(let address): return "email/" + address
        }
    }

    var pickable: Bool {
        switch kind {
        case .unlocking, .nothing: return false
        case .hybrid(_, let busy): return !busy
        default: return true
        }
    }
}

/// What the rows are made of, and the rules that make them: pure, so the
/// tests hold every state the design draws.
enum SuggestRows {
    struct Input {
        var yab: [Login] = []
        var yabOn = true
        /// Connected managers in order, each with what is known of it.
        var managers: [Manager] = []
        var host = ""
        /// A password box, a password box for a new password, and the
        /// account a password step is for.
        var secret = false
        var fresh = false
        var named: String? = nil
        /// A new password made for this box, and who would keep it.
        var generated: String? = nil
        var saver: String? = nil
        /// The Space the box is in, and every Space's emoji and name. A
        /// login saved in this one, in none, or in one not listed here (a
        /// Space deleted, or another Mac's) is this Space's; the rest are
        /// listed after, dimmed (Arc kept passwords per Space; Yab offers
        /// every one, this Space's first).
        var here: UUID? = nil
        var spaces: [UUID: String] = [:]
        /// Your addresses, best first, when the box asks for an email; and
        /// what is typed in it so far, to narrow them.
        var emails: [String] = []
        var typed = ""
    }

    /// The other Space a login was saved in, as its emoji and name, or nil
    /// when it counts as this one's.
    static func away(_ login: Login, here: UUID?, spaces: [UUID: String]) -> String? {
        guard let here, let space = login.space, space != here else { return nil }
        return spaces[space]
    }

    /// This Space's logins first, then the others', each in the order given.
    static func hereFirst(_ logins: [Login], here: UUID?, spaces: [UUID: String]) -> [Login] {
        logins.filter { away($0, here: here, spaces: spaces) == nil } + logins.filter { away($0, here: here, spaces: spaces) != nil }
    }

    struct Manager: Equatable {
        let provider: String
        var logins: [ManagerVault.Login] = []
        /// What its own menu lists, or that it shows its lock.
        var entries: [ManagerMenus.Entry] = []
        var locked = false
        /// Being unlocked for more than 300 ms.
        var unlocking = false
        /// No API: its own extension fills.
        var hybrid = false
        var busy = false
        /// Its own menu showed, with no login for this site: no row, only
        /// a place looked in.
        var none = false
    }

    static func name(_ id: String) -> String { PasswordManagers.name(id) }

    /// "Yab", "Yab and Bitwarden", "NordPass, 1Password and Yab".
    static func words(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    static func build(_ input: Input) -> [SuggestRow] {
        let host = input.host
        // A box for a new password: one made here, shown as it will go in;
        // kept after by the manager's own offer, else Yab's card.
        if input.secret, input.fresh, let password = input.generated {
            if let saver = input.saver {
                // Apple Passwords is asked on Yab's own card, the others on theirs.
                let then = saver == PasswordManagers.apple ? " · saved in Apple Passwords" : " · \(name(saver)) offers to save it"
                return [SuggestRow(kind: .generate(saver, password: password), title: "Use Strong Password",
                                   detail: then, quick: true, badge: saver, shown: password)]
            }
            guard input.yabOn else { return [] }
            return [SuggestRow(kind: .generate(nil, password: password), title: "Use Strong Password",
                               detail: " · saved in Yab passwords", quick: true, shown: password)]
        }
        let connected = !input.managers.isEmpty
        // One row an account: Yab's first, then each manager's in order,
        // the same name kept in two places said once, both named.
        var users: [String: Int] = [:]
        var rows: [SuggestRow] = []
        var sources: [[String]] = []
        // This Space's (and the shared) first; another Space's come after
        // every manager's, under their own heading. The same name kept in
        // both is this Space's one row.
        let here = input.yab.filter { away($0, here: input.here, spaces: input.spaces) == nil }
        let others = input.yab.filter { away($0, here: input.here, spaces: input.spaces) != nil }
        for login in here {
            let key = login.user.lowercased()
            if users[key] != nil { continue }
            users[key] = rows.count
            rows.append(SuggestRow(kind: .yab(login), group: 0, title: login.user.isEmpty ? "No name" : login.user,
                                   detail: connected ? "Yab" : login.host, used: login.used, host: login.host))
            sources.append(["Yab"])
        }
        for (index, manager) in input.managers.enumerated() {
            let group = index + 1
            if manager.none { continue }
            if manager.unlocking {
                rows.append(SuggestRow(kind: .unlocking(manager.provider), group: group,
                                       title: "Unlocking \(name(manager.provider))…", detail: "Its logins come in here"))
                sources.append([])
                continue
            }
            if manager.locked {
                rows.append(SuggestRow(kind: .locked(manager.provider), group: group,
                                       title: "\(name(manager.provider)) is locked", detail: "Unlock it to see its logins here"))
                sources.append([])
                continue
            }
            if !manager.entries.isEmpty {
                for entry in manager.entries {
                    let key = entry.title.lowercased()
                    if let at = users[key] {
                        if !sources[at].contains(name(manager.provider)) { sources[at].append(name(manager.provider)) }
                        continue
                    }
                    users[key] = rows.count
                    rows.append(SuggestRow(kind: .entry(entry), group: group, title: entry.title,
                                           detail: name(manager.provider), badge: manager.provider, host: host))
                    sources.append([name(manager.provider)])
                }
                continue
            }
            if manager.hybrid {
                rows.append(SuggestRow(kind: .hybrid(manager.provider, busy: manager.busy), group: group,
                                       title: "Fill with \(name(manager.provider))",
                                       detail: manager.busy ? "\(name(manager.provider)) is filling…" : "\(name(manager.provider)) picks the login and fills it"))
                sources.append([])
                continue
            }
            for login in manager.logins {
                let key = login.user.lowercased()
                if let at = users[key], !key.isEmpty {
                    if !sources[at].contains(name(manager.provider)) { sources[at].append(name(manager.provider)) }
                    continue
                }
                users[key] = rows.count
                rows.append(SuggestRow(kind: .managed(login), group: group, title: login.user.isEmpty ? login.title : login.user,
                                       detail: name(manager.provider), badge: manager.provider, host: host))
                sources.append([name(manager.provider)])
            }
        }
        let awayGroup = input.managers.count + 1
        for login in others {
            let key = login.user.lowercased()
            if users[key] != nil { continue }
            users[key] = rows.count
            rows.append(SuggestRow(kind: .yab(login), group: awayGroup, title: login.user.isEmpty ? "No name" : login.user,
                                   detail: connected ? "Yab" : login.host, used: login.used, host: login.host,
                                   away: away(login, here: input.here, spaces: input.spaces)))
            sources.append(["Yab"])
        }
        for index in rows.indices where !sources[index].isEmpty && connected {
            rows[index].detail = "Saved in " + words(sources[index])
        }
        for index in rows.indices {
            if let away = rows[index].away { rows[index].detail = away + " · " + rows[index].detail }
        }
        let accounts = rows.filter {
            switch $0.kind {
            case .yab, .managed, .entry: return true
            default: return false
            }
        }
        let waiting = rows.contains {
            switch $0.kind {
            case .unlocking, .locked: return true
            default: return false
            }
        }
        let hybrid = rows.contains { if case .hybrid = $0.kind { return true }; return false }

        // The password step of an account already chosen: its password,
        // one row, ↩.
        if input.secret, let named = input.named?.lowercased(), !named.isEmpty,
           var only = accounts.first(where: { $0.title.lowercased() == named || $0.title.lowercased().split(separator: "@").first.map(String.init) == named }) {
            only.title = "Password for \(only.title)"
            only.quick = true
            only.used = nil
            return [only]
        }

        // No login here and the box wants an email: your addresses, and
        // nothing else (no rows saying what isn't there).
        if accounts.isEmpty, !waiting, !hybrid, !input.secret {
            let typed = input.typed.trimmingCharacters(in: .whitespaces).lowercased()
            let mails = input.emails.filter { typed.isEmpty || ($0.lowercased().hasPrefix(typed) && $0.lowercased() != typed) }
            if !mails.isEmpty {
                return mails.map { SuggestRow(kind: .email($0), title: $0, quick: mails.count == 1) }
            }
        }

        // Nothing anywhere: where it looked, and the way to the manager.
        if accounts.isEmpty, !waiting, !hybrid {
            guard connected else { return [] }
            let looked = (input.yabOn ? ["Yab"] : []) + input.managers.map { name($0.provider) }
            var out = [SuggestRow(kind: .nothing, title: "No logins for this site", detail: "Looked in " + words(looked))]
            if let first = input.managers.first?.provider {
                out.append(SuggestRow(kind: .open(first), group: 1, title: "Open \(name(first))", detail: "Find it there, or add it"))
            }
            return out
        }

        // Only a manager that fills itself: its row, ↩, and the way to it.
        if accounts.isEmpty, !waiting, hybrid {
            var out = rows
            if out.count == 1, case .hybrid(let id, _) = out[0].kind {
                out[0].quick = true
                out.append(SuggestRow(kind: .open(id), group: out[0].group, title: "Open \(name(id))", glyph: "arrow.up.right"))
            }
            return out
        }

        // One account and nothing else to wait for: the one row, ↩.
        if accounts.count == 1, rows.count == 1 {
            var only = rows[0]
            only.quick = true
            only.used = nil
            switch only.kind {
            case .managed, .entry: only.detail += " · " + Vault.registrable(host)
            default: break
            }
            return [only]
        }
        if !connected, input.yabOn || accounts.contains(where: { if case .yab = $0.kind { return true }; return false }) {
            rows.append(SuggestRow(kind: .all, group: (rows.last?.group ?? 0), title: "All Passwords"))
        }
        return rows
    }

    /// A strong password: four groups of four, letters
    /// and digits, no look-alikes.
    static func strongPassword() -> String {
        let letters = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        var groups: [String] = []
        for g in 0..<4 {
            groups.append(String((0..<4).map { letters[Int(bytes[g * 4 + $0]) % letters.count] }))
        }
        // At least one digit and one capital, as sites ask.
        var text = groups.joined(separator: "-")
        if !text.contains(where: \.isNumber) { text.replaceSubrange(text.startIndex...text.startIndex, with: "7") }
        if !text.contains(where: \.isUppercase) { text = text.prefix(text.count - 1) + "K" }
        return text
    }
}

/// What Yab knows of the managers for the box the caret is in: the logins
/// read for a site, who is being unlocked and since when, a manager that is
/// filling by itself. Lives beside Browser: rows are made from it each time
/// the box reports.
@MainActor
final class ManagerLists {
    static let shared = ManagerLists()

    struct Site { var at: Date; var logins: [String: [ManagerVault.Login]]; var states: [String: ManagerVault.State] }
    private(set) var sites: [String: Site] = [:]
    /// Unlocking now, and since when: a row shows after 300 ms.
    private(set) var unlocking: [String: Date] = [:]
    private var looking: Set<String> = []
    /// The manager filling by itself after a pick (hybrid), on which tab.
    var busy: (provider: String, tab: Tab.ID)?
    /// A test world's managers, drawn as given (bench manager-stage).
    var staged: [SuggestRows.Manager]?
    var stagedSaver: String?
    var stagedInsecure: Bool?
    /// New passwords made for a box, by the box, so the row shows the same
    /// one while the caret stays.
    var generated: [String: String] = [:]

    func forget() {
        sites = [:]
        ManagerVaults.forget()
    }

    func logins(_ site: String) -> [String: [ManagerVault.Login]] { sites[site]?.logins ?? [:] }
    /// The managers are still being read for this site.
    func isLooking(_ site: String) -> Bool { looking.contains(site) }

    /// Your own addresses, best first: the mail signed in to Yab, then the
    /// names of Yab's logins that are addresses, by how many sites use
    /// each, then the addresses kept for forms. Read again after a minute.
    private var mailsRead: (at: Date, list: [String])?
    func emails(now: Date = Date()) -> [String] {
        if let kept = mailsRead, now.timeIntervalSince(kept.at) < 60 { return kept.list }
        var counts: [String: Int] = [:]
        for entry in Vault.entries() where Self.isEmail(entry.user) { counts[entry.user.lowercased(), default: 0] += 1 }
        let list = Self.ranked(mail: MailCenter.shared.accounts, logins: counts, forms: Wallet.addresses().map(\.email))
        mailsRead = (now, list)
        return list
    }

    nonisolated static func isEmail(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !text.contains(" ")
    }

    nonisolated static func ranked(mail: [String], logins: [String: Int], forms: [String], most: Int = 4) -> [String] {
        var seen = Set<String>(), out: [String] = []
        let byUse = logins.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
        for address in mail + byUse + forms where isEmail(address) {
            let key = address.lowercased()
            if seen.insert(key).inserted { out.append(key) }
        }
        return Array(out.prefix(most))
    }

    func shownUnlocking(_ id: String, now: Date = Date()) -> Bool {
        guard let since = unlocking[id] else { return false }
        return now.timeIntervalSince(since) >= 0.3
    }

    /// Reads every readable manager for this host, unless read in the last
    /// 30 seconds; `changed` after each step that changes the rows.
    func look(_ host: String, changed: @escaping @MainActor () -> Void) {
        let site = Vault.registrable(host)
        if let kept = sites[site], Date().timeIntervalSince(kept.at) < 30 { return }
        guard !looking.contains(site) else { return }
        let readable = ManagerVaults.readable
        guard !readable.isEmpty else { return }
        looking.insert(site)
        Task { @MainActor in
            var found = Site(at: Date(), logins: [:], states: [:])
            for id in readable {
                guard let adapter = ManagerVault.adapter(id) else { continue }
                var state = await adapter.state()
                if state == .locked {
                    unlocking[id] = Date()
                    // The spinner row only for an unlock that takes a while.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
                        if self?.unlocking[id] != nil { changed() }
                    }
                    if await ManagerVaults.unlockIfKept(id, adapter) { state = .open }
                    unlocking[id] = nil
                }
                found.states[id] = state
                ManagerVaults.lastState[id] = state
                if state == .open { found.logins[id] = (try? await adapter.logins(for: host)) ?? [] }
                found.at = Date()
                sites[site] = found
                changed()
            }
            looking.remove(site)
        }
    }

    /// A login saved or changed: read again next time.
    func dirty(_ host: String) {
        sites[Vault.registrable(host)] = nil
    }
}

// MARK: - the browser's side

extension Browser {
    /// The rows for the box, from Yab's logins (already narrowed and
    /// ordered by the caller) and what the managers have: set as the list.
    /// Nil list when there is nothing to show and nobody to ask.
    func showRows(_ tab: Tab, spot: CGRect, site: String, host: String, yab: [Login]) {
        let lists = ManagerLists.shared
        // A box in another site's frame: Yab's own accounts for that site,
        // which fill that frame alone. Managers fill the page.
        let framed = tab.fieldFrame != nil
        let connections = framed ? [] : PasswordManagers.Connections.shared.list
        if !framed { lists.look(host) { [weak self, id = tab.id] in self?.refreshField(id) } }
        let found = lists.logins(Vault.registrable(host))
        let typed = tab.fieldQuery.trimmingCharacters(in: .whitespaces).lowercased()
        var managers: [SuggestRows.Manager] = []
        for connection in connections {
            let id = connection.provider
            guard let adapter = ManagerVault.adapter(id), adapter.depth != .blocked else { continue }
            // Read by Yab: only a tool already signed in here (lastState).
            if adapter.depth == .vault {
                if lists.shownUnlocking(id) {
                    managers.append(.init(provider: id, unlocking: true))
                    continue
                }
                if ManagerVaults.lastState[id] == .open {
                    var logins = found[id] ?? []
                    if !typed.isEmpty { logins = logins.filter { $0.user.lowercased().contains(typed) } }
                    managers.append(.init(provider: id, logins: logins))
                    continue
                }
            }
            // Otherwise its extension's own icon and menu are the list for
            // it, untouched: Yab drawing its own beside them made two lists
            // on one box (1Password without its CLI, its banner read as
            // logins). Agents still sign in through its menu (menuSignIn).
        }
        if !framed, Store.testing, let staged = lists.staged { managers = staged }
        // A new password made here goes in through the page's script.
        let fresh = !framed && tab.fieldSecret && tab.fieldFresh
        let box = (tab.fieldDocument ?? "") + "/" + (tab.fieldIdentity ?? "")
        if fresh, lists.generated[box] == nil { lists.generated[box] = SuggestRows.strongPassword() }
        let input = SuggestRows.Input(
            yab: yab, yabOn: prefs.usesYabPasswords, managers: managers, host: host,
            secret: tab.fieldSecret, fresh: fresh, named: tab.fieldSecret ? (tab.fieldAccount ?? tab.account(on: host)) : nil,
            generated: fresh ? lists.generated[box] : nil,
            saver: Store.testing && lists.staged != nil ? lists.stagedSaver : PasswordManagers.savingManager,
            here: loginSpace(tab), spaces: loginSpaceNames,
            // Only once the managers have said they have nothing here, so
            // an address doesn't flash before their login comes in.
            emails: !framed && tab.fieldEmail && !lists.isLooking(Vault.registrable(host)) ? lists.emails() : [],
            typed: tab.fieldQuery)
        let rows = SuggestRows.build(input)
        guard !rows.isEmpty else {
            suggesting = nil
            fieldPlate = nil
            return
        }
        // Nothing kept anywhere: no list comes up by itself on every new
        // site. The plate stays; pressed, it says where Yab looked.
        if rows.first?.kind == .nothing, plateAsked?.tab != tab.id || plateAsked?.field != tab.fieldIdentity {
            suggesting = nil
            fieldPlate = FieldPlate(tab: tab.id, spot: spot, badge: nil, dark: tab.fieldDark)
            return
        }
        // The managers' own menus out of sight while Yab's lists what they do.
        let listed = Set(rows.compactMap { row -> String? in
            if case .entry(let entry) = row.kind { return entry.provider }
            return nil
        })
        if !listed.isEmpty { ManagerMenus.hide(tab, Array(listed), true) }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: yab, site: site, dark: tab.fieldDark, rows: rows,
                                insecure: Store.testing && lists.stagedInsecure != nil ? lists.stagedInsecure! : Self.insecure(tab.fieldAddress))
        // One source, a manager: its icon at the plate's corner.
        let sourcesShown = Set(rows.compactMap { row -> String? in
            switch row.kind {
            case .managed(let login): return login.provider
            case .entry(let entry): return entry.provider
            case .hybrid(let id, _), .unlocking(let id), .open(let id), .locked(let id): return id
            case .generate(let id, _): return id
            case .yab: return "yab"
            default: return nil
            }
        })
        let badge = sourcesShown.count == 1 ? sourcesShown.first.flatMap { $0 == "yab" ? nil : $0 } : nil
        fieldPlate = FieldPlate(tab: tab.id, spot: spot, badge: badge, dark: tab.fieldDark)
    }

    /// Over plain http to another machine: this Mac's own (localhost,
    /// 127.0.0.1) never crosses a network.
    nonisolated static func insecure(_ url: URL?) -> Bool {
        guard url?.scheme?.lowercased() == "http", let host = url?.host()?.lowercased() else { return false }
        return !(host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "::1" || host == "[::1]")
    }

    /// The box asked again, as if the caret had just come: rows that came
    /// in since (a manager read, an unlock done) are shown.
    func refreshField(_ id: Tab.ID) {
        guard let tab = autofillTab(id), let spot = tab.fieldSpot else { return }
        tab.onField?(tab, spot)
    }

    /// A row taken, by click or Return.
    func chooseRow(_ row: SuggestRow) {
        guard let list = suggesting, let tab = autofillTab(list.tab) else { return }
        let clear = tab.fieldAddress?.scheme?.lowercased() == "http"
        guard let host = curtain.host(of: tab.fieldAddress), (clear ? "http://" : "") + host == list.site else { return }
        // In another site's frame only Yab's own accounts are listed.
        if tab.fieldFrame != nil { guard case .yab = row.kind else { return } }
        switch row.kind {
        case .yab(let login):
            choose(login)
        case .managed(let login):
            dropChoice()
            noteFilled(tab)
            pickedInto = tab.id
            tab.namedAccount(login.user)
            ManagerVaults.fill(login, into: tab) { [weak self] filled in
                switch filled {
                case .filled: self?.markFilled(tab, from: PasswordManagers.name(login.provider))
                case .gone: self?.toaster.pop("\(PasswordManagers.name(login.provider)) didn’t fill it", mark: "exclamationmark.triangle")
                case .refused: break
                case .unasked: self?.cantAskToFill()
                }
            }
        case .open(let id):
            dropChoice()
            PasswordManagers.open(id, in: self)
        case .entry(let entry):
            // Its own menu fills; if the entry went, its own fill instead.
            dropChoice()
            noteFilled(tab)
            pickedInto = tab.id
            tab.namedAccount(entry.title)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if await !ManagerMenus.pick(entry, in: tab) { await ManagerMenus.fill(entry.provider, on: tab, browser: self) }
                try? await Task.sleep(for: .milliseconds(900))
                ManagerMenus.hide(tab, [entry.provider], false)
                ManagerMenus.forget(tab)
            }
        case .locked(let id):
            dropChoice()
            if let item = PasswordManagers.installed(id) { Extensions.here.press(item.id) }
        case .hybrid(let id, _):
            let lists = ManagerLists.shared
            lists.busy = (id, tab.id)
            refreshField(tab.id)
            Task { @MainActor [weak self] in
                guard let self else { return }
                await ManagerMenus.fill(id, on: tab, browser: self)
                try? await Task.sleep(for: .milliseconds(500))
                if lists.busy?.tab == tab.id { lists.busy = nil }
                dropChoice()
                fieldPlate = nil
            }
        case .generate(let saver, let password):
            guard let web = tab.webKitOnly("Authenticated password generation fill") else { return }
            dropChoice()
            noteFilled(tab)
            pickedInto = tab.id
            tab.page.runInYab(Tab.generatedScript(password)) { [weak self] done in
                if (done as? Bool) == true { self?.markFilled(tab, from: saver.map(PasswordManagers.name) ?? "Yab") }
            }
            ManagerLists.shared.generated = [:]
        case .all:
            openAll(.passwords)
        case .email(let address):
            guard let web = tab.webKitOnly("Email fill") else { return }
            dropChoice()
            noteFilled(tab)
            pickedInto = tab.id
            web.runInYab(Tab.emailScript(address)) { _ in }
        case .unlocking, .nothing:
            break
        }
    }

    /// A sign-in filled shows as itself, the name and the dots in its boxes:
    /// no green dot or source tag on them (asked 2026-10-27). Cards and addresses keep theirs.
    func markFilled(_ tab: Tab, from source: String) {}

    private func noteFilled(_ tab: Tab) {
        fieldPlate = nil
    }
}

/// Yab's plate inside the box the list hangs from: the key on a quiet
/// well, 20 pt, 9 pt in from the box's right edge; a manager's icon at its
/// corner when the list is that manager's alone. A click brings the list.
struct FieldPlate: Equatable {
    let tab: Tab.ID
    let spot: CGRect
    var badge: String?
    var dark: Bool?

    /// Where it sits, in the stage's points.
    var frame: CGRect {
        let side: CGFloat = 20
        return CGRect(x: spot.maxX - 9 - side, y: spot.midY - side / 2, width: side, height: side)
    }
}

/// An agent filling a sign-in from a manager, said under the box: its face,
/// who and from where, never the password.
struct AgentFilling: Equatable {
    let tab: Tab.ID
    let spot: CGRect
    let title: String
    let detail: String
    var dark: Bool?
}

extension Tab {
    /// Whether the focused box asks for an email, from what the page's
    /// script said of it.
    nonisolated static func asksEmail(_ body: [String: Any]) -> Bool {
        if body["content"] as? String == "email" { return true }
        let label = (body["label"] as? String ?? "").lowercased()
        return label.contains("email") || label.contains("e-mail")
    }

    /// One of your addresses into the box the caret is in, alone.
    static func emailScript(_ address: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [address])) ?? Data("[\"\"]".utf8)
        return """
        (() => {
          const bytes = Uint8Array.from(atob('\(data.base64EncodedString())'), c => c.charCodeAt(0));
          const [address] = JSON.parse(new TextDecoder().decode(bytes));
          return !!(window.__yabForms && window.__yabForms.email && window.__yabForms.email(address));
        })()
        """
    }

    /// A new password into every empty password box of the form the caret
    /// is in (a sign-up's and its confirmation), as typing puts it.
    static func generatedScript(_ password: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [password])) ?? Data("[\"\"]".utf8)
        return """
        (() => {
          const bytes = Uint8Array.from(atob('\(data.base64EncodedString())'), c => c.charCodeAt(0));
          const [password] = JSON.parse(new TextDecoder().decode(bytes));
          return !!(window.__yabForms && window.__yabForms.generated && window.__yabForms.generated(password));
        })()
        """
    }
}
