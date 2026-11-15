import SwiftUI

/// The Mac Cmd+J veil's alpha stops. The page stays opaque while its words
/// continue under the header and input instead of ending at a hard seam.
/// A conversation's head keeps its first `solid` share opaque, as Messages
/// does: nothing reads behind the status bar and the head's buttons, the
/// words only fade in under the name.
struct ChatScrollVeil: View {
    var from: UnitPoint = .top
    var to: UnitPoint = .bottom
    var solid: CGFloat = 0

    var body: some View {
        let rest = 1 - solid
        ChatInk.list
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: solid),
                    .init(color: .black.opacity(0.85), location: solid + 0.2 * rest),
                    .init(color: .black.opacity(0.5), location: solid + 0.45 * rest),
                    .init(color: .black.opacity(0.18), location: solid + 0.7 * rest),
                    .init(color: .black.opacity(0.04), location: solid + 0.88 * rest),
                    .init(color: .clear, location: 1)
                ], startPoint: from, endPoint: to)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
