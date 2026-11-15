import SwiftUI
import UIKit

/// The actual Mac page header: tile, title and its one-line purpose.
struct SettingsPageHeader: View {
    let page: SettingsPageID
    var body: some View {
        VStack(spacing: Metrics.Settings.heroGap) {
            SettingsTile(page: page, side: Metrics.Settings.heroTile)
            SettingsText(words: SettingsContent.title(page), style: .title2, weight: .bold,
                         alignment: .center, identifier: "settings.page.title", isHeader: true)
                .fixedSize(horizontal: false, vertical: true)
            if let blurb = SettingsIndex.blurb(page) {
                SettingsText(words: blurb, style: .footnote, ink: SettingsInk.footer,
                             alignment: .center, identifier: "settings.page.description")
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Metrics.Settings.heroSide)
            }
        }.frame(maxWidth: .infinity)
            .padding(.top, Metrics.Settings.heroTop)
            .padding(.bottom, Metrics.Settings.heroBottom)
            .contentShape(Rectangle())
            .modifier(SettingsHeaderDismiss())
    }
}

/// A page's real header retains the existing down-to-dismiss gesture.
/// The scrollable preference rows and toolbar buttons own their own input.
struct SettingsHeaderDismiss: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.gesture(DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if abs(value.translation.height) > abs(value.translation.width) {
                    SettingsUI.shared.sheet.drag = max(0, value.translation.height)
                }
            }
            .onEnded { value in
                let ui = SettingsUI.shared
                if abs(value.translation.height) > abs(value.translation.width),
                   value.translation.height > Metrics.Settings.closeDistance || value.velocity.height > Metrics.Settings.closeVelocity {
                    ui.flickNext = true
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    app.surfaces.closeSettings()
                } else { ui.sheet.snap() }
            })
    }
}
