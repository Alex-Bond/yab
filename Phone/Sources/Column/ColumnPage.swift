import SwiftUI

/// The line between what a space keeps and today, with Clear at its end
/// (the spaces' pages draw it as the column did). With the Mac's Today on
/// (Settings › Today › Your Mac's Tabs) it names whose Today is under it,
/// "This iPhone ⌄" or the Mac's name, and the name folds that list.
struct TodayLine: View {
    typealias C = Metrics.Column
    let clear: Bool
    let spaceID: Space.ID
    let isPrivate: Bool
    var separator = true
    /// Whose Today: tapped, it folds or unfolds the list under the line.
    var label: String? = nil
    var folded = false
    var fold: (() -> Void)? = nil
    /// Quiet words at the line's end in place of Clear ("Asleep · 8:12").
    var note: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            if let label {
                Button { fold?() } label: {
                    HStack(spacing: 4) {
                        Text(label)
                            .font(.system(size: C.clearFont, weight: .medium))
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                        Glyph(.chevronDownSmall, size: 16, color: Ink.primary)
                            .rotationEffect(.degrees(folded ? -90 : 0))
                    }
                    .padding(.horizontal, C.clearOutset.width)
                    .padding(.vertical, C.clearOutset.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, -C.clearOutset.width)
                .padding(.vertical, -C.clearOutset.height)
                .padding(.trailing, C.clearGap)
                .accessibilityLabel(label)
                .accessibilityValue(folded ? "folded" : "open")
                .accessibilityIdentifier("newtab.line.\(label)")
            }
            if separator || label != nil {
                Rectangle().fill(Ink.outline.opacity(C.lineAlpha)).frame(height: 1)
            } else {
                Spacer(minLength: 0)
            }
            if clear {
                ColumnClearControl(ink: isPrivate ? Ink.columnClear : Ink.primary, action: action)
                    .padding(.horizontal, -C.clearOutset.width)
                    .padding(.vertical, -C.clearOutset.height)
                    .padding(.leading, C.clearGap)
            } else if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Ink.rowSubtitle)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, C.clearGap)
            }
        }
        .padding(.horizontal, C.rowPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Ink {
    /// Private Clear keeps its glass treatment; public Clear uses primary ink.
    static let columnClear = AppearanceColors.color(0x3C3C43, 0xEBEBF5, alpha: 0.65, darkAlpha: 0.9)
}
