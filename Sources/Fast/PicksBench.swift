import AppKit

// `./bench picks …`, test runs only: rows of a place picked together, the
// way evals/places/picks.py drives them. "seed" fills the five places with
// fixture rows (this world's own diary, keychain items, downloads list,
// wallet and bookmarks); "place" opens one; "rows" picks those rows as
// ⌘-clicks would (the first one plain), "takes" the first N rows the act
// takes, "stretch" adds ⇧↓ steps, "reload" reads the place again; "forget"
// is ⌫; "undo" is ⌘Z; "escape" puts the picks down; "menu" right-clicks
// a row (⌘K's panel up over it), "act" runs the panel's action by its
// title, "unmenu" puts the panel away. The answer says what the place
// lists, what is picked, what the foot says and what the panel lists.

extension Bench {
    func picksCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "picks only works on a --test run"]) }
        if request["seed"] as? Bool == true { seedPicks(browser) }
        if let name = request["place"] as? String, let place = FieldPlace(rawValue: name) {
            if !(browser.fieldShowing && browser.query.place == place) {
                if !browser.fieldShowing { browser.edit() }
                if browser.query.place == place { browser.stockPlace(place) } else { browser.openPlace(place) }
            }
            if request["reload"] as? Bool == true { browser.stockPlace(place) }
        }
        var rows = request["rows"] as? [Int] ?? []
        if let count = request["takes"] as? Int {
            // The first rows the act takes: past your own card in Autofill.
            let list = browser.placeItems
            rows = Array(list.indices.filter { PlacePicks.takes(list[$0]) }.prefix(count))
        }
        if let first = rows.first {
            browser.query.unpick()
            browser.query.spot = first
            for row in rows.dropFirst() { _ = browser.pickClick(row, flags: .command) }
        }
        if let steps = request["stretch"] as? Int {
            for _ in 0..<abs(steps) { _ = browser.pickStep(steps > 0 ? 1 : -1) }
        }
        if request["escape"] as? Bool == true { _ = browser.unpickRows() }
        if let row = request["menu"] as? Int { browser.showActions(forPlaceRow: row) }
        if let title = request["act"] as? String, let action = browser.shownActions.first(where: { $0.title == title }) {
            browser.query.acting = nil
            action.run()
        }
        if request["unmenu"] as? Bool == true { browser.query.acting = nil }
        if request["forget"] as? Bool == true { browser.forgetPicked() }
        if request["undo"] as? Bool == true { browser.undoWindow() }
        let report = {
            let actions = browser.rowActions
            answer(["place": browser.query.place?.rawValue ?? "",
                    "rows": browser.placeItems.map(\.title),
                    "picked": browser.pickedItems.map(\.title),
                    "spot": browser.query.spot,
                    "foot": browser.pickedWords ?? "",
                    "primary": actions.first?.title ?? "",
                    "danger": actions.first?.danger ?? false,
                    "menu": browser.query.acting == nil ? [] : browser.shownActions.map(\.title),
                    "red": browser.query.acting == nil ? [] : browser.shownActions.filter(\.danger).map(\.title)])
        }
        // The diary and the keychain answer on queues of their own.
        if let wait = request["settle"] as? Double {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { report() }
        } else {
            report()
        }
    }

    /// Fixture rows for every place that picks, in this test world only.
    private func seedPicks(_ browser: Browser) {
        let now = Date()
        let pages = ["Field Notes", "Trail Maps", "Tide Tables", "Bird Calls", "Cloud Atlas", "Star Charts"]
        let traces = pages.enumerated().map { index, title in
            History.Trace(key: "", title: title, url: URL(string: "https://omnibox-bench.invalid/\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")!,
                          last: now.addingTimeInterval(-Double(index) * 600), count: 1)
        }
        Diary.shared.seedBench(traces) { _ in }
        for (index, host) in ["north.example", "harbor.example", "meadow.example", "ridge.example", "canyon.example"].enumerated() {
            Vault.save(host: host, user: "jane\(index)@example.com", password: "fixture-\(index)-Q7v", used: now.addingTimeInterval(-Double(index) * 86400))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yab-picks", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (index, name) in ["report.pdf", "photo.jpg", "slides.key", "notes.txt", "archive.zip"].enumerated() {
            let file = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: Data("fixture".utf8)) }
            browser.loot.add(Keep(name: name, from: "files.example", path: file.path, date: now.addingTimeInterval(-Double(index) * 300)))
        }
        for (index, (number, brand)) in [("4242424242424242", "Visa"), ("5555555555554444", "Mastercard"), ("378282246310005", "American Express")].enumerated() {
            Wallet.save(SavedCard(id: "fixture-card-\(index)", number: number, last4: String(number.suffix(4)), brand: brand, name: "Jane Appleseed",
                                  month: 8, year: 2030, used: now.addingTimeInterval(-Double(index) * 3600), saved: nil))
        }
        for (index, city) in ["San Francisco", "Portland"].enumerated() {
            var address = StreetAddress(id: "fixture-address-\(index)")
            address.name = "Jane Appleseed"
            address.street = "\(100 + index) Market St"
            address.city = city
            address.country = "United States"
            Wallet.save(address)
        }
        for (title, link) in [("Field Guide", "https://guide.example/"), ("Weather", "https://weather.example/"),
                              ("Recipes", "https://recipes.example/"), ("Atlas", "https://atlas.example/"), ("Journal", "https://journal.example/")] {
            _ = browser.bookmarks.add(URL(string: link)!, title: title)
        }
    }
}
