import SwiftUI
import UIKit

/// How the Live Activity looks, as the prototype draws it ("Outside Yab",
/// out.1...out.8): the Lock Screen card, the Island's compact, minimal and
/// expanded forms. The widget (YabActivity) shows these; the app draws the
/// same views in its pictures of the Lock Screen and the Island, so the two
/// can't drift apart.
enum ActivityLook {
    // The Lock Screen card (out.3): 14 16 inside, rows 6 apart.
    static let padding = EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)
    static let gap: CGFloat = 6
    static let mark: CGFloat = 22
    static let headGap: CGFloat = 8
    static let headFont: CGFloat = 14
    static let head: CGFloat = 22
    static let titleFont: CGFloat = 21
    static let titleLine: CGFloat = 25.2
    static let lineFont: CGFloat = 14
    static let lineLine: CGFloat = 18.9
    static let buttonsTop: CGFloat = 4
    static let button: CGFloat = 34
    static let buttonPadding: CGFloat = 16
    static let buttonFont: CGFloat = 14.5
    static let buttonGap: CGFloat = 8
    /// The buttons while the iPhone is locked: asleep until Face ID knows the face.
    static let lockedOpacity: Double = 0.42
    /// The card's dark glass: rgba(20, 20, 24, .62).
    static let card = Color(red: 20 / 255, green: 20 / 255, blue: 24 / 255).opacity(0.62)
    /// Needs you, on dark: #FF9F0A.
    static let warn = Color(red: 1, green: 0x9F / 255, blue: 0x0A / 255)
    static let warnInk = Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)

    // The Island, compact (out.1): the site 24 at the left, 8 in; the word 14 at the right, 12 in.
    static let compactIcon: CGFloat = 24
    static let compactLeading: CGFloat = 8
    static let compactTrailing: CGFloat = 12
    static let compactFont: CGFloat = 14
    static let minimalMark: CGFloat = 20

    // The Island, expanded: head 15, title 19, line 13.5, buttons 32.
    static let expandedHeadFont: CGFloat = 15
    static let expandedStateFont: CGFloat = 13
    static let expandedTitle: CGFloat = 19
    static let expandedLine: CGFloat = 13.5
    static let expandedButton: CGFloat = 32
    static let expandedButtonPadding: CGFloat = 14
    static let expandedButtonFont: CGFloat = 14
    static let expandedGap: CGFloat = 10
}

/// The Lock Screen's card.
struct TaskLockCard<ButtonView: View>: View {
    let state: TaskActivityAttributes.ContentState
    /// Locked: the buttons sleep until Face ID knows the face.
    var locked = false
    /// No news for a while (the activity's stale date passed): the head says so.
    var stale = false
    @ViewBuilder let button: (ActivityButton) -> ButtonView

    var body: some View {
        VStack(alignment: .leading, spacing: ActivityLook.gap) {
            HStack(spacing: ActivityLook.headGap) {
                ActivityMark(size: ActivityLook.mark)
                Text(state.name)
                    .font(.system(size: ActivityLook.headFont, weight: .black))
                    .tracking(-0.01 * ActivityLook.headFont)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(stale ? "Not updated" : state.head)
                    .font(.system(size: ActivityLook.headFont, weight: state.warn && !stale ? .semibold : .medium))
                    .tracking(-0.01 * ActivityLook.headFont)
                    .foregroundStyle(state.warn && !stale ? ActivityLook.warn : Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            .frame(height: ActivityLook.head)
            Text(state.title)
                .font(.system(size: ActivityLook.titleFont, weight: .semibold))
                .tracking(-0.02 * ActivityLook.titleFont)
                .lineLimit(2)
                .frame(minHeight: ActivityLook.titleLine)
            Text(state.line)
                .font(.system(size: ActivityLook.lineFont))
                .tracking(-0.01 * ActivityLook.lineFont)
                .foregroundStyle(Color.white.opacity(0.75))
                .lineLimit(2)
                .frame(minHeight: ActivityLook.lineLine)
            if !state.buttons.isEmpty {
                HStack(spacing: ActivityLook.buttonGap) {
                    Spacer(minLength: 0)
                    ForEach(state.buttons, id: \.action) { item in
                        button(item)
                    }
                }
                // Dimmed as one, as CSS fades the row: each capsule keeps its
                // words readable over its own fill.
                .compositingGroup()
                .opacity(locked ? ActivityLook.lockedOpacity : 1)
                .padding(.top, ActivityLook.buttonsTop)
            }
        }
        .foregroundStyle(.white)
        .padding(ActivityLook.padding)
        .accessibilityElement(children: .contain)
    }
}

/// A Lock Screen button's face: a 34 capsule, the word 14.5 semibold.
struct ActivityButtonLabel: View {
    let button: ActivityButton
    var expanded = false

    var body: some View {
        Text(button.label)
            .font(.system(size: expanded ? ActivityLook.expandedButtonFont : ActivityLook.buttonFont, weight: .semibold))
            .tracking(-0.01 * (expanded ? ActivityLook.expandedButtonFont : ActivityLook.buttonFont))
            .foregroundStyle(ink)
            .padding(.horizontal, expanded ? ActivityLook.expandedButtonPadding : ActivityLook.buttonPadding)
            .frame(height: expanded ? ActivityLook.expandedButton : ActivityLook.button)
            .background(fill, in: Capsule(style: .continuous))
    }

    private var ink: Color {
        switch button.style {
        case .plain: .white
        case .warn: ActivityLook.warnInk
        case .primary: .black
        }
    }

    private var fill: Color {
        switch button.style {
        case .plain: Color.white.opacity(expanded ? 0.16 : 0.18)
        case .warn: ActivityLook.warn
        case .primary: .white
        }
    }
}

/// The Island's left: the site the Mac is on.
struct TaskIslandLeading: View {
    let state: TaskActivityAttributes.ContentState

    var body: some View {
        ActivityFavicon(icon: state.icon, size: ActivityLook.compactIcon)
    }
}

/// The Island's right: two words, orange when it needs you, gray while it
/// waits for the Mac.
struct TaskIslandTrailing: View {
    let state: TaskActivityAttributes.ContentState

    var body: some View {
        Text(state.word)
            .font(.system(size: ActivityLook.compactFont, weight: .semibold))
            .tracking(-0.01 * ActivityLook.compactFont)
            .foregroundStyle(state.warn ? ActivityLook.warn : state.status == "waits" ? Color.white.opacity(0.6) : .white)
            .lineLimit(1)
    }
}

/// Beside another app's activity: Yab's mark in a circle.
struct TaskIslandMinimal: View {
    var body: some View {
        ActivityMark(size: ActivityLook.minimalMark)
    }
}

/// Held: the step, what it says, Stop and Open.
struct TaskIslandExpanded<ButtonView: View>: View {
    let state: TaskActivityAttributes.ContentState
    @ViewBuilder let button: (ActivityButton) -> ButtonView

    var body: some View {
        VStack(alignment: .leading, spacing: ActivityLook.expandedGap) {
            HStack(spacing: ActivityLook.headGap) {
                ActivityMark(size: ActivityLook.mark)
                Text(state.name)
                    .font(.system(size: ActivityLook.expandedHeadFont, weight: .semibold))
                    .tracking(-0.01 * ActivityLook.expandedHeadFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(state.head)
                    .font(.system(size: ActivityLook.expandedStateFont, weight: .medium))
                    .tracking(-0.01 * ActivityLook.expandedStateFont)
                    .foregroundStyle(state.warn ? ActivityLook.warn : Color.white.opacity(0.65))
            }
            Text(state.title)
                .font(.system(size: ActivityLook.expandedTitle, weight: .semibold))
                .tracking(-0.02 * ActivityLook.expandedTitle)
                .lineLimit(1)
            Text(state.line)
                .font(.system(size: ActivityLook.expandedLine))
                .tracking(-0.01 * ActivityLook.expandedLine)
                .foregroundStyle(Color.white.opacity(0.7))
                .lineLimit(1)
            HStack(spacing: ActivityLook.buttonGap) {
                Spacer(minLength: 0)
                ForEach(state.expandedButtons, id: \.action) { item in
                    button(item)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

extension TaskActivityAttributes.ContentState {
    /// The expanded Island's buttons: the Lock Screen's, and Open while it
    /// runs (Stop · Open).
    var expandedButtons: [ActivityButton] {
        if buttons.contains(where: { $0.action == "stop" }) {
            return buttons + [ActivityButton(action: "open", label: "Open", style: .primary)]
        }
        return buttons
    }
}

/// Yab's mark, the glass wink, from the shared asset catalog.
struct ActivityMark: View {
    var size: CGFloat = 22

    var body: some View {
        Image("YabMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A site's icon, from the bundle's Favicons (by its host, favicons.json),
/// or the prototype's drawn tile for the sites it draws (TAP's red T).
struct ActivityFavicon: View {
    let icon: String
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let image = ActivityFavicons.image(icon) {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(ActivityFavicons.round.contains(icon) ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)))
            } else {
                let tile = ActivityFavicons.drawn[icon] ?? (Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255), String((icon.first ?? "?").uppercased()))
                RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                    .fill(tile.0)
                    .overlay {
                        Text(tile.1)
                            .font(.system(size: (size * 0.5).rounded(), weight: .bold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ActivityFavicons {
    /// The prototype's round marks.
    static let round: Set<String> = ["github", "lumen", "nordbutik", "google"]
    /// The prototype's drawn tiles among the tasks' sites.
    static let drawn: [String: (Color, String)] = [
        "tap": (Color(red: 0xE2 / 255, green: 0, blue: 0x1A / 255), "T"),
    ]

    private static let hosts: [String: String] = {
        struct Entry: Decodable { let key: String; let host: String; let source: String? }
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Favicons/favicons.json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.filter { $0.source != "drawn" }.map { ($0.key, $0.host) }, uniquingKeysWith: { a, _ in a })
    }()

    static func image(_ icon: String) -> UIImage? {
        guard drawn[icon] == nil, let host = hosts[icon],
              let url = Bundle.main.resourceURL?.appendingPathComponent("Favicons/\(host).png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
