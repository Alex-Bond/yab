import SwiftUI

/// The minus that takes a row out of a list: a
/// short round-ended line on a small square plate that lifts under the
/// pointer, its tip saying Remove. One look for the field's places, the
/// field's fallbacks and the awake sites.
struct RemoveMinus: View {
    var label = "Remove"
    var keys: String?
    var side: KeyTip.Side = .below
    let action: () -> Void

    var body: some View {
        // design: Raycast's line is about 2/5 of its plate, 1.5 pt thick
        Button(action: action) { Symbol("minus", size: 10, side: 14, stroke: 1.5) }
            .buttonStyle(.yab(.secondary, .small, icon: .square))
            .keyTip("Remove", keys: keys, side: side)
            .accessibilityLabel(label)
    }
}
