import SwiftUI

/// A section: its title in small capitals, the white group of rows, the
/// words under it.
struct SettingsSection: View {
    let section: SettingsSectionModel
    let tap: (SettingsRowModel) -> Void

    @ScaledMetric(relativeTo: .caption) private var titleHeight = Metrics.Settings.sectionTitle
    @ScaledMetric(relativeTo: .footnote) private var footerLeading = Metrics.Settings.footerLeading

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title = section.title {
                Text(title)
                    .textCase(.uppercase)
                    .font(.caption.weight(.semibold))
                    .tracking(Metrics.Settings.sectionTracking * Metrics.Settings.sectionFont)
                    .foregroundStyle(SettingsInk.section)
                    // The prototype's line box is the font's size (line-height 1),
                    // the words centered in it.
                    .frame(height: titleHeight)
                    .padding(.horizontal, Metrics.Settings.sectionInset)
                    .padding(.bottom, Metrics.Settings.sectionTitleGap)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("settings.section.\(section.id)")
            }
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    SettingsRow(row: row, first: index == 0, tap: tap)
                }
            }
            .background(SettingsInk.group, in: RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Settings.groupRadius, style: .continuous))
            if let footer = section.footer {
                Text(footer)
                    .font(.footnote)
                    // Lines 1.4 apart, as the prototype sets them, the extra
                    // shared above and below each.
                    .tracking(Metrics.Settings.footerTracking)
                    .lineSpacing(footerLeading)
                    .padding(.vertical, footerLeading / 2)
                    .foregroundStyle(SettingsInk.footer)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Give the text its own actual ground rather than relying
                    // on the translucent sheet behind its accessibility node.
                    .background(SettingsInk.pageGround)
                    .padding(.horizontal, Metrics.Settings.sectionInset)
                    .padding(.top, Metrics.Settings.footerGap)
                    .accessibilityIdentifier("settings.footer.\(section.id)")
            }
        }
    }
}

/// One row: the icon in its gray box, the title, the value at the right and
/// a chevron, a tick, a switch or nothing. Big text stacks the value under
/// the title instead of cutting either; nothing is ever cut to one line.
struct SettingsRow: View {
    let row: SettingsRowModel
    let first: Bool
    let tap: (SettingsRowModel) -> Void

    @ScaledMetric(relativeTo: .body) private var minHeight = Metrics.Settings.row

    var body: some View {
        Group {
            switch row.kind {
            case let .toggle(binding):
                Toggle(isOn: binding) { label }
                    // The system's green: the sheet's tint is its ink, white
                    // in dark, which made the switch a white blot.
                    .tint(Color(uiColor: .systemGreen))
                    .padding(.horizontal, Metrics.Settings.rowPadding)
                    .frame(minHeight: minHeight)
                    .accessibilityIdentifier("settings.row.\(row.id)")
            case let .choice(selected, _) where row.id.hasPrefix("appearance."):
                AppearanceChoiceButton(words: row.title, selected: selected,
                                       identifier: identifier, minimumHeight: minHeight) { tap(row) }
                    .frame(maxWidth: .infinity, minHeight: minHeight)
            case .info:
                content
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.row.\(row.id)")
            default:
                Button { tap(row) } label: { content }
                    .buttonStyle(SettingsRowStyle(ground: rowGround))
                    .foregroundColor(SettingsInk.text)
                    .accessibilityIdentifier(identifier)
                    .accessibilityAddTraits(row.isSelected ? .isSelected : [])
            }
        }
        .overlay(alignment: .top) {
            if !first {
                Rectangle()
                    .fill(SettingsInk.hairline)
                    .frame(height: Metrics.Settings.hairline)
                    .padding(.leading, row.icon == nil ? Metrics.Settings.rowPadding : Metrics.Settings.hairlineInset)
                    .accessibilityHidden(true)
            }
        }
        // Where the row is on screen: its page grows out of it, and goes
        // back into it.
        .id(row.id)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            SettingsUI.shared.rowFrames[row.id] = frame
        }
    }

    private var rowGround: Color {
        if case .choice = row.kind { return SettingsInk.group }
        return .clear
    }

    private var identifier: String {
        if case .choice = row.kind { return "settings.choice.\(row.id)" }
        return "settings.row.\(row.id)"
    }

    private var content: some View {
        HStack(spacing: Metrics.Settings.rowGap) {
            label
            accessory
        }
        .padding(.horizontal, Metrics.Settings.rowPadding)
        // Words of several lines (the Recovery Key) stand off the row's edges
        // as a stacked title and value do.
        .padding(.vertical, row.spacious ? Metrics.Settings.stackPadding : 0)
        .frame(minHeight: minHeight)
        .contentShape(Rectangle())
    }

    /// The icon, then the title and the value: on one line while they fit,
    /// the value under the title when they don't. The same two texts either
    /// way, so the person's text size only moves them.
    private var label: some View {
        HStack(spacing: Metrics.Settings.rowGap) {
            if let icon = row.icon { SettingsIcon(icon: icon) }
            RowWords(gap: Metrics.Settings.rowGap, lineGap: Metrics.Settings.stackGap, padding: Metrics.Settings.stackPadding) {
                SettingsRowTitle(words: row.title, ground: rowGround, danger: row.danger)
                if let value = row.value {
                    Text(value)
                        .font(.body)
                        .foregroundStyle(SettingsInk.value)
                }
            }
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch row.kind {
        case .page, .join:
            Glyph(.chevronRight, size: Metrics.Settings.chevron, color: SettingsInk.chevron)
        case let .choice(selected, _):
            if selected {
                Glyph(.checkmark1Small, size: Metrics.Settings.check, color: SettingsInk.text)
            } else {
                // Keep the title's width without a transparent painted image.
                Spacer(minLength: 0)
                    .frame(width: Metrics.Settings.check)
                    .accessibilityHidden(true)
            }
        case .toggle, .info, .action:
            EmptyView()
        }
    }
}

private struct SettingsRowPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var settingsRowPressed: Bool {
        get { self[SettingsRowPressedKey.self] }
        set { self[SettingsRowPressedKey.self] = newValue }
    }
}

/// A choice's text describes its own ground to accessibility. While held,
/// let the row's existing pressed fill show through under every word.
private struct SettingsRowTitle: View {
    let words: String
    let ground: Color
    /// iOS's red, for an action that ends something.
    var danger = false
    @Environment(\.settingsRowPressed) private var pressed

    var body: some View {
        Text(words)
            .font(.body)
            .foregroundColor(danger ? Color(uiColor: .systemRed) : SettingsInk.text)
            .background(pressed ? Color.clear : ground)
    }
}

/// A row's title and value: side by side, the value at the right on its
/// own line's height, while both fit at their full width (the prototype's
/// nowrap value beside a flexible title); else the title over the value,
/// each wrapping as it needs. A lone title wraps in place.
struct RowWords: Layout {
    let gap: CGFloat
    let lineGap: CGFloat
    let padding: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = ideal.map(\.width).reduce(0, +) + gap * CGFloat(max(0, ideal.count - 1))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural
        return arrange(width: width, subviews: subviews, ideal: ideal).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let plan = arrange(width: bounds.width, subviews: subviews, ideal: ideal)
        for (index, subview) in subviews.enumerated() where index < plan.frames.count {
            let frame = plan.frames[index].offsetBy(dx: bounds.minX, dy: bounds.minY + (bounds.height - plan.size.height) / 2)
            subview.place(at: frame.origin, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews, ideal: [CGSize]) -> (size: CGSize, frames: [CGRect]) {
        guard let title = subviews.first else { return (.zero, []) }
        if subviews.count == 1 {
            let size = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
            return (CGSize(width: width, height: size.height), [CGRect(origin: .zero, size: CGSize(width: width, height: size.height))])
        }
        let value = subviews[1]
        if ideal[0].width + gap + ideal[1].width <= width {
            let height = max(ideal[0].height, ideal[1].height)
            return (CGSize(width: width, height: height), [
                CGRect(x: 0, y: (height - ideal[0].height) / 2, width: width - gap - ideal[1].width, height: ideal[0].height),
                CGRect(x: width - ideal[1].width, y: (height - ideal[1].height) / 2, width: ideal[1].width, height: ideal[1].height),
            ])
        }
        let top = title.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let under = value.sizeThatFits(ProposedViewSize(width: width, height: nil))
        let height = padding + top.height + lineGap + under.height + padding
        return (CGSize(width: width, height: height), [
            CGRect(x: 0, y: padding, width: width, height: top.height),
            CGRect(x: 0, y: padding + top.height + lineGap, width: width, height: under.height),
        ])
    }
}

/// The 28-point gray box with the row's glyph, the agent's face or Yab's mark.
struct SettingsIcon: View {
    let icon: SettingsRowModel.Icon

    @ScaledMetric(relativeTo: .body) private var box = Metrics.Settings.iconBox
    @ScaledMetric(relativeTo: .body) private var glyph = Metrics.Settings.rowIcon

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Metrics.Settings.iconRadius, style: .continuous)
                .fill(SettingsInk.iconBox)
            switch icon {
            case let .glyph(name):
                Glyph(name, size: glyph, color: SettingsInk.text)
            case .face:
                AgentFace(size: glyph, color: SettingsInk.text)
            case .mark:
                YabMark(size: glyph)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.Settings.markRadius, style: .continuous))
            }
        }
        .frame(width: box, height: box)
        .accessibilityHidden(true)
    }
}

/// A row under the finger turns a little gray, as iOS's lists do.
struct SettingsRowStyle: ButtonStyle {
    var ground: Color = .clear

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.settingsRowPressed, configuration.isPressed)
            .background(configuration.isPressed ? SettingsInk.pressed : ground)
    }
}

/// The round ✕ and ‹ of a sheet's head: the app's one round sheet button
/// (Chats/RoundSheetButton, the prototype's .ai-rb: white .7, a hairline
/// ring, a light shadow), 44 to see and to hit, its glyph 22.
struct SheetHeadButton: View {
    let glyph: GlyphName
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        RoundSheetButton(glyph: glyph, size: Metrics.Settings.headIcon, id: id, label: label, action: action)
    }
}

/// The grabber at a sheet's top: 38 x 5, 7 under its edge.
struct SheetGrabber: View {
    var body: some View {
        Capsule()
            .fill(SettingsInk.grab)
            .frame(width: Metrics.Settings.grab.width, height: Metrics.Settings.grab.height)
            .padding(.top, Metrics.Settings.grabTop)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}
