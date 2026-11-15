import SwiftUI
import WidgetKit

/// Search: New Tab's field from the Home Screen or the Lock Screen.
struct SearchWidget: Widget {
    var body: some WidgetConfiguration { SearchWidgets.configuration(.search) }
}

/// Ask: a new chat from the Home Screen or the Lock Screen.
struct AskWidget: Widget {
    var body: some WidgetConfiguration { SearchWidgets.configuration(.ask) }
}

/// Both widgets hold nothing that changes: one entry, never refreshed. A
/// tap opens Yab at yab://new or yab://ask (Entrances in the app).
enum SearchWidgets {
    static func configuration(_ kind: SearchWidgetKind) -> some WidgetConfiguration {
        StaticConfiguration(kind: kind.widgetKind, provider: SearchWidgetTimeline()) { _ in
            SearchWidgetEntryView(kind: kind)
        }
        .configurationDisplayName(kind.galleryName)
        .description(kind.galleryDescription)
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct SearchWidgetEntry: TimelineEntry {
    let date: Date
}

struct SearchWidgetTimeline: TimelineProvider {
    func placeholder(in context: Context) -> SearchWidgetEntry { SearchWidgetEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (SearchWidgetEntry) -> Void) {
        completion(SearchWidgetEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SearchWidgetEntry>) -> Void) {
        completion(Timeline(entries: [SearchWidgetEntry(date: .now)], policy: .never))
    }
}

struct SearchWidgetEntryView: View {
    let kind: SearchWidgetKind
    @Environment(\.widgetFamily) private var family

    var body: some View {
        SearchWidgetFace(kind: kind, family: family)
            .containerBackground(for: .widget) {
                // The Lock Screen draws its own backing (AccessoryWidgetBackground in the face).
                if family == .systemSmall { EntranceLook.surface }
            }
            .widgetURL(kind.route.url)
    }
}
