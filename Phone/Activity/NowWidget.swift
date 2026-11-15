import SwiftUI
import WidgetKit

/// Now: the Mac's rows about mail that waits on you, from the Home Screen
/// and the Lock Screen. The app keeps them in the App Group as sync brings
/// them and asks for a new drawing (NowShelf); between, nothing changes.
struct NowWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: NowShelf.widgetKind, provider: NowWidgetTimeline()) { entry in
            NowWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Now")
        .description("Mail waiting on you, as Now on your Mac has it. Opens in your mail app.")
        .supportedFamilies([.systemMedium, .systemSmall, .accessoryRectangular])
    }
}

struct NowWidgetEntry: TimelineEntry {
    let date: Date
    let rows: [NowShelfRow]
}

struct NowWidgetTimeline: TimelineProvider {
    func placeholder(in context: Context) -> NowWidgetEntry { NowWidgetEntry(date: .now, rows: []) }

    func getSnapshot(in context: Context, completion: @escaping (NowWidgetEntry) -> Void) {
        completion(NowWidgetEntry(date: .now, rows: NowShelf.shared.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NowWidgetEntry>) -> Void) {
        completion(Timeline(entries: [NowWidgetEntry(date: .now, rows: NowShelf.shared.read())], policy: .never))
    }
}

struct NowWidgetEntryView: View {
    let entry: NowWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NowWidgetFace(rows: entry.rows, family: family)
            .containerBackground(for: .widget) {
                if family != .accessoryRectangular { EntranceLook.surface }
            }
            // The medium's rows and fields are links of their own; the
            // small and the Lock Screen's open the top row, or Search.
            .widgetURL(entry.rows.first?.link ?? YabRoute.newTab.url)
    }
}
