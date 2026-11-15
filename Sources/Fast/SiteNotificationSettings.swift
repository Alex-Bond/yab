import SwiftUI

/// The answers Site Controls keeps, in Websites' table, even after a tab closes.
struct SiteNotificationSettings: View {
    @State private var sites = SiteNotices.sites()

    var body: some View {
        Section {
            SettingsRow("Notifications", detail: "Sites that have asked to send notifications.") { EmptyView() }
                .settingsAnchor("site-notifications")
            ForEach(sites) { site in
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        HostMark(host: site.host)
                        Text(verbatim: site.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    MenuCell(title: SettingsWords.format("Notifications for %@", [site.title]),
                             options: [(SettingsWords.text("Allow"), true), (SettingsWords.text("Deny"), false)],
                             selection: Binding(get: { site.allowed }, set: {
                                 SiteNotices.remember(site.origin, $0)
                                 sites = SiteNotices.sites()
                             }), trailing: true)
                    Button { remove(site) } label: { Symbol("xmark", size: 10, weight: .medium) }
                        .buttonStyle(.yab(.quiet, .small, icon: .square))
                        .keyTip("Remove")
                        .accessibilityLabel(SettingsWords.format("Remove %@", [site.title]))
                }
                .contentShape(Rectangle())
                .contextMenu {
                    Button(SettingsWords.text("Remove")) { remove(site) }
                }
            }
            if sites.isEmpty {
                SettingsNote("No sites have asked to send notifications.")
            }
        }
        .onAppear { sites = SiteNotices.sites() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
            sites = SiteNotices.sites()
        }
    }

    private func remove(_ site: SiteNotices.Permission) {
        SiteNotices.forget(site.origin)
        sites = SiteNotices.sites()
    }
}
