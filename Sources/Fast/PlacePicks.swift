import AppKit

// Several rows of a place at once, as a Finder list picks them: ⌘-click
// takes a row in or out, ⇧-click and ⇧↑/⇧↓ stretch from where the picking
// started, Escape puts them all down. With two or more picked the foot
// says how many and offers one act on all of them, "Delete 3 Pages",
// which ⌫ and ⌃X do too. History, Downloads and Bookmarks go at once and
// come back with ⌘Z or the corner's Undo; Passwords, cards and addresses
// are asked about once, with the count, as one of them alone is.
//
// History, Passwords, Downloads, Autofill and Bookmarks pick; the rest
// keep their one chosen row. One row chosen is the plain list, as before.

/// The picking itself, apart from any list.
enum PlacePicks {
    /// The places whose rows can be picked together.
    static let places: Set<FieldPlace> = [.history, .passwords, .downloads, .autofill, .bookmarks]

    /// ⌘-click on `index`: in or out of the picks. Nothing picked yet, the
    /// row chosen until then is the first of them.
    static func toggle(_ picks: Set<String>, ids: [String], spot: Int, at index: Int) -> Set<String> {
        var out = picks
        if out.isEmpty, ids.indices.contains(spot), spot != index { out.insert(ids[spot]) }
        guard ids.indices.contains(index) else { return out }
        if out.contains(ids[index]) { out.remove(ids[index]) } else { out.insert(ids[index]) }
        return out
    }

    /// ⇧-click, ⇧↑ or ⇧↓: every row from the anchor to `index`, both ends in.
    static func span(ids: [String], from anchor: Int, to index: Int) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let a = max(0, min(anchor, ids.count - 1))
        let b = max(0, min(index, ids.count - 1))
        return Set(ids[min(a, b)...max(a, b)])
    }

    /// What one row of the place is called, and many.
    static func noun(_ place: FieldPlace, _ count: Int) -> String {
        let one = count == 1
        switch place {
        case .history: return one ? "page" : "pages"
        case .passwords: return one ? "password" : "passwords"
        case .downloads: return one ? "download" : "downloads"
        case .autofill: return one ? "entry" : "entries"
        case .bookmarks: return one ? "bookmark" : "bookmarks"
        default: return one ? "item" : "items"
        }
    }

    /// The word its single rows' own act uses: a page is deleted from the
    /// history; a download or a bookmark is
    /// removed from the list; the rest forgotten.
    static func verb(_ place: FieldPlace) -> String {
        switch place {
        case .history: return "Delete"
        case .downloads, .bookmarks: return "Remove"
        default: return "Forget"
        }
    }

    /// The foot's left: "3 pages selected".
    static func selected(_ place: FieldPlace, _ count: Int) -> String {
        "\(count) \(noun(place, count)) selected"
    }

    /// The act on all of them: "Delete 3 Pages".
    static func title(_ place: FieldPlace, _ count: Int) -> String {
        "\(verb(place)) \(count) \(noun(place, count).capitalized)"
    }

    /// Whether a row is one the act takes: a page, a password, a download
    /// kept, a card or an address, a bookmark or a folder. Downloads still
    /// coming, your own card and the rows that bring things in are not.
    static func takes(_ item: PlaceItem) -> Bool {
        switch item.what {
        case .visit, .login, .kept, .card, .address, .bookmark: return true
        default: return false
        }
    }
}

extension Browser {
    /// Whether the place open now picks rows together.
    var picksRows: Bool {
        guard let place = query.place, query.edit == nil else { return false }
        return PlacePicks.places.contains(place)
    }

    /// The rows picked, in the list's order, while two or more are.
    var pickedItems: [PlaceItem] {
        guard query.picks.count > 1, picksRows else { return [] }
        return placeItems.filter { query.picks.contains($0.id) }
    }

    /// Two or more rows picked: the foot and ⌫ are theirs.
    var picking: Bool { pickedItems.count > 1 }

    /// The foot's left while picking: "3 pages selected".
    var pickedWords: String? {
        guard let place = query.place else { return nil }
        let count = pickedItems.count
        return count > 1 ? PlacePicks.selected(place, count) : nil
    }

    /// A click on a row with ⌘ or ⇧ held: picked. False for a plain click,
    /// or in a place that doesn't pick, which chooses the row as before.
    func pickClick(_ index: Int, flags: NSEvent.ModifierFlags) -> Bool {
        let flags = flags.intersection([.command, .shift])
        guard !flags.isEmpty else { return false }
        if query.place == .files { return pickFileClick(index, flags: flags) }
        guard picksRows else { return false }
        let list = placeItems
        guard list.indices.contains(index), PlacePicks.takes(list[index]) else { return false }
        let ids = list.map(\.id)
        let taken = Set(list.filter(PlacePicks.takes).map(\.id))
        if flags.contains(.shift) {
            let anchor = query.pickAnchor ?? query.spot
            query.picks = PlacePicks.span(ids: ids, from: anchor, to: index).intersection(taken)
            query.pickAnchor = anchor
            query.spot = index
            return true
        }
        let picks = PlacePicks.toggle(query.picks.intersection(ids), ids: ids, spot: query.spot, at: index).intersection(taken)
        query.picks = picks
        query.pickAnchor = index
        // One left: that one is the chosen row, as a plain click leaves it.
        if picks.count == 1, let one = picks.first, let at = ids.firstIndex(of: one) {
            query.spot = at
        } else {
            query.spot = index
        }
        return true
    }

    /// ⇧↑ and ⇧↓: the picks stretched a row up or down from where they
    /// started. True when the place took the key.
    func pickStep(_ step: Int) -> Bool {
        guard picksRows, query.acting == nil, emojiWords == nil else { return false }
        let list = placeItems
        guard !list.isEmpty else { return true }
        let anchor = query.pickAnchor ?? query.spot
        let next = max(0, min(list.count - 1, query.spot + step))
        let taken = Set(list.filter(PlacePicks.takes).map(\.id))
        query.picks = PlacePicks.span(ids: list.map(\.id), from: anchor, to: next).intersection(taken)
        query.pickAnchor = anchor
        query.spot = next
        return true
    }

    /// Escape: the picks put down, the chosen row kept. True when there
    /// were two or more to put down.
    func unpickRows() -> Bool {
        let shown = picking
        query.unpick()
        return shown
    }

    /// A row of a place right-clicked: ⌘K's panel, as for the rows of
    /// ⌘T. On one of two or more picked, their one act ("Delete 3 Pages");
    /// on any other, that row chosen, the picks put down, and its own.
    func showActions(forPlaceRow index: Int) {
        let list = placeItems
        guard list.indices.contains(index) else { return }
        if picking, query.picks.contains(list[index].id) { return showActions(forSpot: query.spot) }
        if query.edit != nil, index != query.spot { cancelEdit() }
        query.unpick()
        showActions(forSpot: index)
    }

    /// The one act while picking, in the foot and on ⌫ and ⌃X.
    var pickedAction: FieldAction? {
        let items = pickedItems
        guard items.count > 1, let place = query.place else { return nil }
        return FieldAction(id: "delete", title: PlacePicks.title(place, items.count), keys: "⌫", symbol: "trash", danger: true) {
            self.forgetPicked()
        }
    }

    /// Every row picked, gone: at once with ⌘Z to bring them back, or
    /// asked about first where nothing brings them back.
    func forgetPicked() {
        let items = pickedItems
        guard items.count > 1, let place = query.place else { return }
        let count = items.count
        query.unpick()
        switch place {
        case .history:
            var keys: [String] = []
            var pretty: [String] = []
            for item in items {
                guard case .visit(let url, _, let key, _, _) = item.what else { continue }
                if !keys.contains(key) { keys.append(key) }
                pretty.append(History.key(for: url))
            }
            let ids = Set(items.map(\.id))
            // Gone from the list at once; the diary follows on its queue.
            query.stock.visits.removeAll { ids.contains($0.id) }
            settle()
            let gone = history.take(pretty)
            Diary.shared.take(keys: keys) { [weak self] taken in
                guard let self else { return }
                if self.query.place == .history { self.askHistory() }
                self.undoable("Deleted \(count) \(PlacePicks.noun(place, count))", mark: "trash") { [weak self] in
                    self?.history.putBack(gone)
                    Diary.shared.giveBack(taken) { [weak self] in
                        if self?.query.place == .history { self?.askHistory() }
                    }
                }
            }
        case .downloads:
            let keeps = items.compactMap { item -> Keep? in
                if case .kept(let keep) = item.what { return keep }
                return nil
            }
            let gone = loot.forget(keeps)
            settle()
            undoable("Removed \(count) \(PlacePicks.noun(place, count))", mark: "xmark") { [weak self] in
                self?.loot.putBack(gone)
            }
        case .bookmarks:
            let nodes = items.compactMap { item -> Bookmark? in
                if case .bookmark(let node) = item.what { return node }
                return nil
            }
            let inside = nodes.filter(\.isFolder).reduce(0) { $0 + Bookmarks.count($1.children ?? []) }
            let remove = { [weak self] in
                guard let self else { return }
                let backs = nodes.map { self.bookmarks.removeUndoably($0.id) }
                self.settle()
                self.undoable("Removed \(count) \(PlacePicks.noun(place, count))", mark: "trash") {
                    backs.reversed().forEach { $0() }
                }
            }
            guard inside > 0 else { return remove() }
            // A folder with sites in it is asked about, as one alone is.
            close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Remove \(count) bookmarks?",
                    detail: "Folders go with everything in them, \(inside == 1 ? "1 bookmark" : "\(inside.formatted()) bookmarks").",
                    glyph: "trash", yes: "Remove", danger: true
                ))
                if yes { remove() }
            }
        case .passwords:
            let entries = items.compactMap { item -> Vault.Entry? in
                if case .login(let entry) = item.what { return entry }
                return nil
            }
            let names = entries.map { "\($0.host) · \($0.user)" }
            forgetPasswords(entries, asking: Question(
                    title: "Forget \(count) passwords?",
                    detail: "They go from this Mac’s keychain, with their one-time codes. This can’t be undone.",
                    lines: Array(names.prefix(3)), folded: Array(names.dropFirst(3)), lineGlyph: "key",
                    glyph: "trash", yes: "Forget", danger: true
            ))
        case .autofill:
            var cards: [SavedCard] = []
            var addresses: [StreetAddress] = []
            for item in items {
                if case .card(let card) = item.what { cards.append(card) }
                if case .address(let address) = item.what { addresses.append(address) }
            }
            let names = cards.map(\.title) + addresses.map(\.title)
            close()
            Task { @MainActor in
                let yes = await Questions.shared.ask(Question(
                    title: "Forget \(count) entries?",
                    detail: "This can’t be undone.",
                    lines: Array(names.prefix(3)), folded: Array(names.dropFirst(3)),
                    glyph: "trash", yes: "Forget", danger: true
                ))
                guard yes else { return }
                cards.forEach { Wallet.forget(card: $0.id) }
                addresses.forEach { Wallet.forget(address: $0.id) }
            }
        default:
            break
        }
    }

    /// The chosen row kept inside the list that is left.
    private func settle() {
        query.spot = min(query.spot, max(0, placeItems.count - 1))
    }

    /// Done, and ⌘Z or the corner's Undo takes it back.
    private func undoable(_ words: String, mark: String, _ back: @escaping () -> Void) {
        let step = did(back)
        toaster.pop(words, mark: mark, undo: { [weak self] in self?.undo(step: step) })
    }
}
