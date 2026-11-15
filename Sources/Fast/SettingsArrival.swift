import SwiftUI

/// A page that is not a form but a way in, in the middle of the pane:
/// Spaces and Sync while off, Memory while empty, Mail before an account.
/// It scrolls only when the window is too short for it.
struct ArrivalFrame<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        GeometryReader { proxy in
            ThreadScrollView {
                content
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .font(.system(size: 13))
    }
}

/// The way in with the page's tile, its name and a line on what it is
/// for; what the feature shows and its button come under them.
struct ArrivalPage<Content: View>: View {
    let page: SettingsPage
    let title: String
    let blurb: String
    @ViewBuilder let content: Content

    var body: some View {
        ArrivalFrame {
            VStack(spacing: 0) {
                PenTileView(page: page).frame(width: 56, height: 56)
                Text(SettingsWords.text(title))
                    .font(.system(size: 17, weight: .medium))
                    .padding(.top, 16)
                SettingsText(SettingsWords.text(blurb))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                    .padding(.top, 6)
                content
            }
        }
    }
}
