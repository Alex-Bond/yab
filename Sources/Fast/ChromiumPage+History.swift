import AppKit
import YabCoreClient

/// The existing door list consumes rows and actions, never engine objects.
@MainActor
struct PageNavigationList {
    let stops: [Stop]
    let address: (Stop) -> URL?
    let take: (Stop) -> Void
    let history: () -> TabHistory

    init(web: PageView, back: Bool) {
        let (rows, pages) = web.stops(back: back)
        stops = rows
        address = { [weak web] in web?.address(of: $0, pages: pages) }
        take = { [weak web] in web?.take($0, back: back, pages: pages) }
        history = { [weak web] in web?.history() ?? TabHistory(entries: [], pick: { _ in }) }
    }

    init(stops: [Stop], address: @escaping (Stop) -> URL?, take: @escaping (Stop) -> Void,
         history: @escaping () -> TabHistory) {
        self.stops = stops; self.address = address; self.take = take; self.history = history
    }
}

struct ChromiumHistorySnapshot {
    struct Entry: Equatable {
        let id: Int
        let url: URL
        let title: String
        var named: (title: String, host: String) {
            let host = url.host() ?? ""
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title.isEmpty ? (host.isEmpty ? url.absoluteString : host) : title, host)
        }
    }
    let entries: [Entry]
    let currentIndex: Int

    init(_ value: JSONValue) throws {
        guard case .array(let rows) = value["entries"], rows.count <= 4096,
              let index = value["currentIndex"].number, index.isFinite,
              index.rounded() == index, index >= -1, index < Double(max(1, rows.count)) else {
            throw YabCoreError.remote("Invalid native navigation history")
        }
        var parsed: [Entry] = [], ids = Set<Int>()
        for row in rows {
            guard let number = row["id"].number, number >= 1, number <= Double(Int32.max), number.rounded() == number,
                  let raw = row["url"].string, let url = URL(string: raw), url.scheme != nil,
                  ids.insert(Int(number)).inserted else { throw YabCoreError.remote("Invalid native history entry") }
            parsed.append(Entry(id: Int(number), url: url, title: row["title"].string ?? ""))
        }
        guard parsed.isEmpty ? index == -1 : index >= 0 else { throw YabCoreError.remote("Invalid native current entry") }
        entries = parsed; currentIndex = Int(index)
    }

    func pages(back: Bool) -> [Entry] {
        guard entries.indices.contains(currentIndex) else { return [] }
        return back ? Array(entries[..<currentIndex].reversed()) : Array(entries.dropFirst(currentIndex + 1))
    }

    @MainActor func list(page: ChromiumPage, tab: Tab, back: Bool) -> PageNavigationList {
        let pages = pages(back: back)
        let stops = Swipe.rows(pages.map(\.named), from: back ? tab.fromTitle?(tab) : nil)
        return PageNavigationList(stops: stops, address: { stop in
            guard (stop.kind == .page || stop.kind == .run), pages.indices.contains(stop.index) else { return nil }
            return pages[stop.index].url
        }, take: { [weak page, weak tab] stop in
            switch stop.kind {
            case .page, .run:
                guard pages.indices.contains(stop.index) else { return }
                page?.command("history.go", ["entry": .number(Double(pages[stop.index].id))])
            case .from:
                if let tab { tab.onFrom?(tab) }
            case .search: break // DoorList opens its existing history panel.
            }
        }, history: { [weak page] in
            let newest = Array(entries.enumerated().reversed())
            let rows = newest.enumerated().map { index, item in
                TabHistory.Entry(id: index, title: item.element.named.title, host: item.element.named.host,
                                 url: item.element.url, current: item.offset == currentIndex)
            }
            return TabHistory(entries: rows) { index in
                guard newest.indices.contains(index), newest[index].offset != currentIndex else { return }
                page?.command("history.go", ["entry": .number(Double(newest[index].element.id))])
            }
        })
    }
}

extension ChromiumPage {
    func navigationHistory() async throws -> ChromiumHistorySnapshot {
        let value = try await navigationRequest("history.read")
        return try ChromiumHistorySnapshot(value)
    }
}
