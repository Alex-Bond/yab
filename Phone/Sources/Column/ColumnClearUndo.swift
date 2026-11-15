import SwiftUI

/// Cleared's receipt with Undo: a real bounded control, never a full-screen hit layer.
struct ColumnClearUndo: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        if let receipt = app.tabClear.visibleReceipt {
            HStack(spacing: Metrics.Column.rowGap) {
                Glyph(.broom, size: Metrics.Toast.icon)
                Text("Cleared \(receipt.count)").font(.body).lineLimit(1)
                Spacer(minLength: 0)
                // The 44 square inside the label: a frame around the button
                // only spaced the word, and the finger had just the word's
                // own frame (42.7 wide).
                Button { Haptics.play(.light, reason: Haptics.Reason.undone); Task { await app.tabClear.undo(receipt.id) } } label: {
                    Text("Undo").font(.body.weight(.semibold))
                        .frame(minWidth: Metrics.touch, minHeight: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .accessibilityIdentifier("column.clear.undo")
            }
            .padding(.horizontal, Metrics.Chrome.labelPadding)
            .padding(.vertical, Metrics.Toast.gap)
            .frame(minHeight: Metrics.touch)
            .glassEffect(.regular, in: Capsule())
            .accessibilityIdentifier("column.clear.receipt")
            .environment(\.colorScheme, receipt.before.isPrivate ? .dark : AppAppearance.current)
            // On screen: Undo's six seconds start now, not under the spaces that made it.
            .task(id: receipt.id) { app.tabClear.seen(receipt.id) }
        }
    }
}

/// An automatic receipt is actionable while the browser itself is in front.
/// Only the real capsule has hits; there is no full-screen intercepting plane.
struct BrowserClearUndo: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        GeometryReader { geo in
            if app.tabClear.visibleReceipt != nil,
               !app.field.shown, !app.chatSheet.shown,
               !app.surfaces.settings, !app.surfaces.join, app.surfaces.menu == nil,
               !app.surfaces.pageSwiping, app.surfaces.chromeOpacity > 0.5,
               !FirstLaunch.shows(app) {
                let geometry = ChromeGeometry(size: geo.size, folded: app.chrome.folded, hasNow: app.nowItem != nil)
                let top = app.nowItem != nil ? min(geometry.plateTouch.minY, geometry.now.minY) : geometry.plateTouch.minY
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    ColumnClearUndo()
                }
                .padding(.horizontal, Metrics.Edge.bar)
                .padding(.bottom, max(0, geo.size.height - top) + Metrics.Toast.gap)
            }
        }
        .ignoresSafeArea()
    }
}
