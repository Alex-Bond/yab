import AppKit
import NaturalLanguage

/// Choices for the empty field over a page. Kept actions still need something
/// to act on; a video action never appears on a page without a video.
@MainActor
enum FieldPageRows {
    enum Kind: String, CaseIterable, Identifiable {
        case errorsAndNetwork = "page-action:errorsAndNetwork"
        case inspectElement = "page-action:inspectElement"
        case hardReload = "page-action:hardReload"
        case floatVideo = "page-action:floatVideo"
        case translatePage = "page-action:translatePage"
        case reader = "page-action:reader"
        case muteTab = "page-action:muteTab"
        case actualSize = "page-action:actualSize"
        case fillSign = "page-action:fillSign"
        case tracking
        case extensionButtons = "extension-buttons"
        case extensionCommands = "extension-commands"
        case userscriptCommands = "userscript-commands"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .tracking: "Copy URL with Tracking"
            case .extensionButtons: "Extension Buttons"
            case .extensionCommands: "Extension Commands"
            case .userscriptCommands: "Userscript Commands"
            default: FieldPageRows.command(rawValue)?.title ?? rawValue
            }
        }
        var symbol: String {
            switch self {
            case .tracking: "link"
            case .extensionButtons, .extensionCommands: "puzzlepiece.extension"
            case .userscriptCommands: "curlybraces"
            default: FieldPageRows.command(rawValue).map(FieldPageRows.symbol) ?? "link"
            }
        }
        var category: String {
            switch self {
            case .fillSign: "PDF"
            case .extensionButtons, .extensionCommands: "Extensions"
            case .userscriptCommands: "Userscripts"
            case .errorsAndNetwork, .inspectElement, .hardReload: "Developer"
            default: "Page"
            }
        }
        var developer: Bool { category == "Developer" }
        var legacyGroup: String {
            switch self {
            case .extensionButtons, .extensionCommands: "extensions"
            case .userscriptCommands: "userscripts"
            default: developer ? "developer" : "actions"
            }
        }
    }

    /// The rows every page starts with, in their order. One taken away
    /// waits in Add Row.
    enum Base: String, CaseIterable, Identifiable {
        case copy, markdown, duplicate

        var id: String { rawValue }
        var title: String {
            switch self {
            case .copy: "Copy URL"
            case .markdown: "Copy Markdown Link"
            case .duplicate: "Duplicate Tab"
            }
        }
        var symbol: String {
            switch self {
            case .copy: "link"
            case .markdown: "markdown"
            case .duplicate: "plus.square.on.square"
            }
        }
    }

    struct Entry: Equatable, Identifiable {
        let id: String
        let title: String
        var kind: Kind? { FieldPageRows.kind(id) }
        var name: String { Kind(rawValue: id)?.title ?? title }
    }

    static let keptKey = "field.page.kept"
    static let hiddenKey = "field.page.hiddenKinds"
    static let orderKey = "field.page.order"
    static let baseKey = "field.page.base"
    static let standard = Kind.allCases

    /// Native toggles share a kind. Add-on entries keep their instance ids.
    nonisolated static func kind(_ id: String) -> Kind? {
        if let kind = Kind(rawValue: id) { return kind }
        if id == "page-action:unmuteTab" { return .muteTab }
        if id.hasPrefix("us:") { return .userscriptCommands }
        if id.hasPrefix("ext:"), let command = id.split(separator: "\u{1F}").last {
            return ExtensionTip.pressCommands.contains(String(command)) ? .extensionButtons : .extensionCommands
        }
        return nil
    }

    private static func readEntries(_ key: String, in defaults: UserDefaults) -> [Entry] {
        var seen = Set<String>()
        return (defaults.array(forKey: key) as? [[String: String]] ?? []).compactMap {
            guard let id = $0["id"], let title = $0["title"], seen.insert(id).inserted else { return nil }
            return Entry(id: id, title: title)
        }
    }

    private static func writeEntries(_ entries: [Entry], in defaults: UserDefaults) {
        defaults.set(entries.map { ["id": $0.id, "title": $0.title] }, forKey: keptKey)
    }

    /// The presence of either new list also protects choices arriving by sync.
    /// Old switches and per-instance exclusions are read only on this first use.
    static func migrate(in defaults: UserDefaults = Store.settings) {
        guard defaults.object(forKey: orderKey) == nil, defaults.object(forKey: hiddenKey) == nil else { return }
        let excluded = Set(readEntries("field.page.hidden", in: defaults).compactMap(\.kind))
        let kept = readEntries(keptKey, in: defaults).filter { entry in
            entry.kind.map { !excluded.contains($0) } ?? true
        }
        let keptKinds = Set(kept.compactMap(\.kind))
        let hidden = standard.filter { kind in
            let on = defaults.object(forKey: "field.page." + kind.legacyGroup) as? Bool ?? (kind != .userscriptCommands)
            return excluded.contains(kind) || (!on && !keptKinds.contains(kind))
        }
        defaults.set(hidden.map(\.rawValue), forKey: hiddenKey)
        defaults.set(standard.map(\.rawValue), forKey: orderKey)
        writeEntries(kept, in: defaults)
    }

    static func entries(in defaults: UserDefaults = Store.settings) -> [Entry] {
        migrate(in: defaults)
        return readEntries(keptKey, in: defaults)
    }

    static func order(in defaults: UserDefaults = Store.settings) -> [Kind] {
        migrate(in: defaults)
        var seen = Set<Kind>()
        let saved = (defaults.stringArray(forKey: orderKey) ?? []).compactMap(Kind.init(rawValue:))
        return (saved + standard).filter { seen.insert($0).inserted }
    }

    static func hidden(in defaults: UserDefaults = Store.settings) -> Set<Kind> {
        migrate(in: defaults)
        return Set((defaults.stringArray(forKey: hiddenKey) ?? []).compactMap(Kind.init(rawValue:)))
    }

    static func visible(in defaults: UserDefaults = Store.settings) -> [Kind] {
        let kept = Set(entries(in: defaults).compactMap(\.kind)), hidden = hidden(in: defaults)
        return order(in: defaults).filter { !hidden.contains($0) && !kept.contains($0) }
    }

    /// Hidden kinds first, then kept kinds, both in the saved priority order.
    static func addable(in defaults: UserDefaults = Store.settings) -> [Kind] {
        let order = order(in: defaults), hidden = hidden(in: defaults)
        let kept = Set(entries(in: defaults).compactMap(\.kind))
        return order.filter { hidden.contains($0) } + order.filter { !hidden.contains($0) && kept.contains($0) }
    }

    static func keep(_ entry: Entry, on: Bool, in defaults: UserDefaults = Store.settings) {
        var kept = entries(in: defaults).filter { $0.id != entry.id }
        if on {
            kept.append(entry)
            if let kind = entry.kind { show(kind, in: defaults) }
        }
        writeEntries(kept, in: defaults)
    }

    static func hide(_ kind: Kind, in defaults: UserDefaults = Store.settings) {
        var hidden = hidden(in: defaults)
        hidden.insert(kind)
        defaults.set(order(in: defaults).filter { hidden.contains($0) }.map(\.rawValue), forKey: hiddenKey)
        writeEntries(entries(in: defaults).filter { $0.kind != kind }, in: defaults)
    }

    private static func show(_ kind: Kind, in defaults: UserDefaults) {
        let hidden = hidden(in: defaults).subtracting([kind])
        defaults.set(order(in: defaults).filter { hidden.contains($0) }.map(\.rawValue), forKey: hiddenKey)
    }

    static func add(_ kind: Kind, in defaults: UserDefaults = Store.settings) {
        show(kind, in: defaults)
        writeEntries(entries(in: defaults).filter { $0.kind != kind }, in: defaults)
    }

    static func move(_ kind: Kind, before other: Kind?, in defaults: UserDefaults = Store.settings) {
        guard kind != other else { return }
        var next = order(in: defaults).filter { $0 != kind }
        next.insert(kind, at: other.flatMap { next.firstIndex(of: $0) } ?? next.endIndex)
        defaults.set(next.map(\.rawValue), forKey: orderKey)
    }

    static func moveKept(_ id: String, before other: String?, in defaults: UserDefaults = Store.settings) {
        var next = entries(in: defaults)
        guard id != other, let from = next.firstIndex(where: { $0.id == id }) else { return }
        let entry = next.remove(at: from)
        next.insert(entry, at: other.flatMap { target in next.firstIndex { $0.id == target } } ?? next.endIndex)
        writeEntries(next, in: defaults)
    }

    static func base(in defaults: UserDefaults = Store.settings) -> [Base] {
        guard let saved = defaults.stringArray(forKey: baseKey) else { return Base.allCases }
        var seen = Set<Base>()
        return saved.compactMap(Base.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    static func hiddenBase(in defaults: UserDefaults = Store.settings) -> [Base] {
        let shown = base(in: defaults)
        return Base.allCases.filter { !shown.contains($0) }
    }

    static func hide(_ row: Base, in defaults: UserDefaults = Store.settings) {
        defaults.set(base(in: defaults).filter { $0 != row }.map(\.rawValue), forKey: baseKey)
    }

    static func add(_ row: Base, in defaults: UserDefaults = Store.settings) {
        defaults.set((base(in: defaults).filter { $0 != row } + [row]).map(\.rawValue), forKey: baseKey)
    }

    static func move(_ row: Base, before other: Base?, in defaults: UserDefaults = Store.settings) {
        guard row != other else { return }
        var next = base(in: defaults).filter { $0 != row }
        next.insert(row, at: other.flatMap { next.firstIndex(of: $0) } ?? next.endIndex)
        defaults.set(next.map(\.rawValue), forKey: baseKey)
    }

    struct Candidate {
        let id: String
        let kind: Kind
        var row: Suggestion
    }

    /// Kept rows need a live candidate. Developer rows take the contextual
    /// group on local pages, with the saved order breaking ties between kinds.
    static func choose(_ candidates: [Candidate], in defaults: UserDefaults = Store.settings) -> (kept: [Candidate], site: [Candidate]) {
        let hidden = hidden(in: defaults), entries = entries(in: defaults)
        var seen = Set<String>()
        let live = candidates.filter { !hidden.contains($0.kind) && seen.insert($0.id).inserted }
        let kept = entries.flatMap { entry in live.filter { $0.id == entry.id || $0.kind.rawValue == entry.id } }
        let keptKinds = Set(entries.compactMap(\.kind))
        let available = live.filter { !keptKinds.contains($0.kind) }
        let developer = available.contains { $0.kind.developer }
        let site = ordered(available, in: defaults).filter { !developer || $0.kind.developer }.prefix(3)
        return (kept, Array(site))
    }

    static func ordered(_ candidates: [Candidate], in defaults: UserDefaults = Store.settings) -> [Candidate] {
        let order = order(in: defaults)
        return candidates.enumerated().sorted {
            let a = order.firstIndex(of: $0.element.kind) ?? order.count
            let b = order.firstIndex(of: $1.element.kind) ?? order.count
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    nonisolated static func command(_ what: String) -> Command? {
        guard what.hasPrefix("page-action:") else { return nil }
        return Command(rawValue: String(what.dropFirst("page-action:".count)))
    }

    nonisolated static func symbol(_ command: Command) -> String {
        switch command {
        case .translatePage: "yab.translate"
        case .errorsAndNetwork: "exclamationmark.triangle"
        case .inspectElement: "yab.element"
        case .reader: "yab.bookopen"
        default: command.symbol
        }
    }

    static func language(_ hint: String, sample: String, preferred: String = Locale.preferredLanguages.first ?? "en") -> String? {
        let code = hint.isEmpty ? NLLanguageRecognizer.dominantLanguage(for: sample)?.rawValue : hint
        guard let code, let language = Locale.Language(identifier: code).languageCode?.identifier,
              language != "und", language != Locale.Language(identifier: preferred).languageCode?.identifier else { return nil }
        return Locale(identifier: "en_US").localizedString(forLanguageCode: language)
    }
}

struct FieldPageFacts {
    var address: URL?
    var video = false
    var language: String?
}

extension Browser {
    /// Read the live document on each opening, including videos added since
    /// load. A late answer from a previous page never changes this field.
    func refreshPageRows(_ tab: Tab?) {
        guard let tab, let web = tab.built, !tab.isBlank else { return }
        let address = tab.address
        web.callAsyncQuietly("""
        return {video: !!document.querySelector('video'), language: document.documentElement.lang || '',
                sample: (document.body?.innerText || '').slice(0, 2000)};
        """, in: nil, in: Web.world) { [weak self, weak tab, weak web] result in
            guard let self, let tab, tab.built === web, tab.address == address,
                  let data = (try? result.get()) as? [String: Any] else { return }
            tab.fieldPageFacts = FieldPageFacts(address: address, video: data["video"] as? Bool == true,
                language: FieldPageRows.language(data["language"] as? String ?? "", sample: data["sample"] as? String ?? ""))
            guard self.editing, self.fieldPage === tab, self.untouched != nil, self.query.place == nil, self.query.acting == nil else { return }
            self.settlePageRows()
        }
    }

    func pageRows(on tab: Tab) -> [Suggestion] {
        let choices = FieldPageRows.choose(pageCandidates(on: tab), in: pageRowSettings)
        let host = tab.address?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? "this page"
        let heading = choices.site.allSatisfy { $0.kind.developer } ? "Developer" : tab.paper.pdf ? "On this PDF" : "On " + host
        return choices.kept.map { candidate in
            var row = candidate.row
            row.pageRowID = candidate.id
            row.pageHeading = "This Page"
            return row
        } + choices.site.map { candidate in
            var row = candidate.row
            row.pageRowID = candidate.id
            row.pageHeading = heading
            return row
        }
    }

    private func pageCandidates(on tab: Tab, addons: Bool = true) -> [FieldPageRows.Candidate] {
        var out: [FieldPageRows.Candidate] = []
        func add(_ command: Command, _ detail: String = "", title: String? = nil) {
            let id = "page-action:" + command.kept.rawValue
            guard let kind = FieldPageRows.kind(id) else { return }
            out.append(.init(id: id, kind: kind,
                row: Suggestion(key: title ?? command.title, title: detail, url: nil, kind: .page("page-action:" + command.rawValue))))
        }
        // Guest windows have their own page, not the browser's active tab.
        if fieldGuest == nil, tab === active {
            if !tab.paper.pdf, tab.isLocal || tab.isDev || tab.address?.isFileURL == true {
                let errors = tab.devLog.errors
                add(.errorsAndNetwork, errors == 0 ? "" : "\(errors) error\(errors == 1 ? "" : "s")")
                add(.inspectElement)
                add(.hardReload)
            }
        }
        let facts = tab.fieldPageFacts.address == tab.address ? tab.fieldPageFacts : FieldPageFacts()
        if facts.video, everyTab.contains(where: { $0 === tab }) { add(.floatVideo) }
        if let language = facts.language, pageTranslation.canTranslate(tab) {
            switch pageTranslation.phase(for: tab) {
            case .original, .failed: add(.translatePage, "from " + language)
            default: break
            }
        }
        if tab.readable || tab.reader { add(.reader, title: tab.reader ? "Leave Reading Mode" : "Reading Mode") }
        if AudioWatch.canMute, tab.noisy, !tab.muted { add(.muteTab, "playing") }
        if tab.muted { add(.unmuteTab) }
        if abs(tab.zoom - 1) > 0.001 { add(.actualSize, "\(Int((tab.zoom * 100).rounded()))%") }
        if tab.paper.pdf, tab.paper.desk == nil { add(.fillSign) }
        if let url = tab.address {
            let names = Diary.sharingParameters(url)
            if !names.isEmpty {
                out.append(.init(id: "tracking", kind: .tracking,
                    row: Suggestion(key: "Copy URL with Tracking", title: names.joined(separator: ", "), url: nil, kind: .page("tracking"))))
            }
        }
        if addons, fieldGuest == nil, tab === active {
            out += pageExtensionRows(on: tab)
            out += pageUserscriptRows(on: tab)
        }
        return out
    }

    /// Hidden kinds and saved order affect the quiet list only. Native
    /// actions remain searchable even when the experimental menu catalog is off.
    func typedPageRows(_ text: String) -> [(Suggestion, Double)] {
        guard let tab = fieldPage, text.count >= 2 else { return [] }
        return pageCandidates(on: tab, addons: false).compactMap { candidate -> (Suggestion, Double)? in
            guard candidate.kind.legacyGroup == "actions" || candidate.kind.developer else { return nil }
            let row = candidate.row
            if case .page(let what) = row.kind, let command = FieldPageRows.command(what) {
                if Command.normalizedName(row.key) == Command.normalizedName(text) { return (row, 4) }
                guard let score = command.score(text, in: self) else { return nil }
                return (row, score)
            }
            guard let score = Wording.score(text, title: row.key, words: "tracking original link parameters utm") else { return nil }
            return (row, score)
        }
    }

    func pageActionMatches(_ words: String) -> [(Suggestion, Double)] {
        guard let tab = fieldPage else { return [] }
        if words.isEmpty { return FieldPageRows.ordered(pageCandidates(on: tab), in: pageRowSettings).map { ($0.row, 1) } }
        let native = typedPageRows(words)
        let extensions = extensionCommandRows(words).rows.map { ($0, 1.0) }
        let scripts = userscriptRows(words).map { ($0, 1.0) }
        return native + extensions + scripts
    }

    func pageRowActions(_ row: Suggestion, _ actions: [FieldAction]) -> [FieldAction] {
        guard untouched != nil, let id = row.pageRowID else { return favoriting(row, actions) }
        let entry = FieldPageRows.Entry(id: id, title: row.key)
        let kept = FieldPageRows.entries(in: pageRowSettings).contains { $0.id == id }
        return actions + [
            FieldAction(id: "favorite", title: kept ? "Remove from This Page" : "Keep in This Page",
                        keys: Keymap.shared.text(.fieldFavorite), symbol: kept ? "pin.slash" : "pin", group: 2) {
                FieldPageRows.keep(entry, on: !kept, in: self.pageRowSettings)
                self.settlePageRows()
            },
            FieldAction(id: "hide-page-row", title: "Don't Show on Pages", symbol: "eye.slash", group: 2) {
                if let kind = entry.kind { FieldPageRows.hide(kind, in: self.pageRowSettings) }
                self.settlePageRows()
            }
        ]
    }

    private func settlePageRows() {
        let selected = query.current.flatMap { offers.indices.contains($0) ? offers[$0].id : nil }
        let was = query.current
        query.acting = nil
        query.pointed = nil
        replaceTyped(typed)
        picked = selected.flatMap { id in offers.firstIndex { $0.id == id } } ?? was.map { min($0, max(0, offers.count - 1)) }
    }

    func takePageAction(_ command: Command, on tab: Tab?) {
        guard let tab else { return }
        switch command {
        case .reader: toggleReader(tab)
        case .muteTab: tab.mute(true)
        case .unmuteTab: tab.mute(false)
        case .actualSize:
            if tab === active { resetZoom() } else { tab.resetZoom() }
        case .fillSign: fillSign(tab)
        case .floatVideo: floatVideoFromField(tab)
        case .translatePage: pageTranslation.toggle(tab)
        default:
            if let entry = MenuCommands.entries[command], entry.available(self) { entry.run(self) }
            else { command.run(in: self) }
        }
    }
}
