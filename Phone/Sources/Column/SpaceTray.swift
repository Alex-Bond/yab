import Observation
import SwiftUI
import UIKit

/// A space's draft while Settings edits it. A new space is made once, on Create.
@MainActor
@Observable
final class SpaceTrayModel {
    enum Step: String { case menu, spaces, edit, name, emoji, color, signIns }
    var step: Step = .menu
    private(set) var target: Space.ID?
    private(set) var creating = false
    var name = ""
    var emoji = "🌐"
    var emojiSearch = ""
    var look = SpaceLook(color: RGB(168, 195, 160))
    private(set) var lookChanged = false
    private var nameChanged = false
    private var emojiChanged = false
    private var openedLook = SpaceLook(color: RGB(168, 195, 160))
    @ObservationIgnored let diagnosticID = UUID().uuidString
    @ObservationIgnored var diagnosticOwner: String?

    func start(_ step: Step, space: Space, creating: Bool = false) {
        self.step = step
        target = space.id
        self.creating = creating
        name = creating ? "" : space.name
        emoji = creating ? "🌐" : space.emoji
        emojiSearch = ""
        look = creating ? SpaceLook(color: RGB(168, 195, 160)) : space.look ?? SpaceLook(color: space.tint)
        openedLook = look
        lookChanged = false
        nameChanged = false
        emojiChanged = false
    }

    func rename(_ name: String) { self.name = name; nameChanged = true }
    func pickEmoji(_ emoji: String) { self.emoji = emoji; emojiChanged = true }
    func changeLook(_ look: SpaceLook) {
        if let diagnosticOwner { LookEditDiagnostics.record("draft.before", owner: diagnosticOwner, look: self.look, space: target) }
        self.look = look; lookChanged = true
        if let diagnosticOwner { LookEditDiagnostics.record("draft.after", owner: diagnosticOwner, look: self.look, space: target) }
    }

    /// Kept while it is being changed, as the Mac's card keeps it (saveSoon):
    /// the spaces' cards and the space's tint follow the finger.
    @ObservationIgnored private var soon: Task<Void, Never>?
    func commitSoon(in browser: BrowserStore) {
        soon?.cancel()
        soon = Task { @MainActor [weak self, weak browser] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, let browser else { return }
            self.commit(in: browser)
        }
    }

    func commit(in browser: BrowserStore) {
        if let diagnosticOwner { LookEditDiagnostics.record("commit.before", owner: diagnosticOwner, look: look, space: target) }
        guard !creating, let target, nameChanged || emojiChanged || lookChanged else { return }
        if lookChanged { look = look.mergingChanges(from: openedLook, into: browser.space(target)?.look) }
        browser.setSpace(target, name: nameChanged ? name : nil, emoji: emojiChanged ? emoji : nil,
                         look: lookChanged ? look : nil)
        if let saved = browser.space(target) { name = saved.name; emoji = saved.emoji }
        if let diagnosticOwner { LookEditDiagnostics.record("commit.stored", owner: diagnosticOwner,
                                                             look: browser.space(target)?.look ?? look, space: target) }
        openedLook = look
        nameChanged = false
        emojiChanged = false
        lookChanged = false
    }

    func created() { target = nil; creating = false; lookChanged = false; nameChanged = false; emojiChanged = false }
}

/// A space's look as a ground, the way the spaces' card wears its color
/// (NewTabSpaces' wash): its colors top to bottom, lighter at the top.
struct SpaceLookWash: View {
    @Environment(\.colorScheme) private var scheme
    let look: SpaceLook
    var body: some View {
        // The colors picked, lifted only as far as dark words need (SpaceLook.readable).
        let colors = look.displayColors(dark: scheme == .dark).map { scheme == .dark ? $0 : SpaceLook.readable($0) }
        let top = colors.first ?? look.primary
        let light = { (v: Int) in (Double(v) + (255 - Double(v)) * 0.35) / 255 }
        ZStack {
            LinearGradient(colors: [Color(red: light(top.r), green: light(top.g), blue: light(top.b))] + colors.map { Color(rgb: $0) },
                           startPoint: .top, endPoint: .bottom)
            if scheme == .dark { Color.black.opacity(0.45) }
            LookGrainFill(amount: look.grain)
            LookDrawingsFill(drawings: look.drawings, strength: look.drawingsStrength, ground: colors.first ?? look.primary)
        }
    }
}

struct SpaceLookTile: View {
    @Environment(\.colorScheme) private var scheme
    let emoji: String
    let look: SpaceLook?
    let tint: RGB
    let isPrivate: Bool
    let size: CGFloat
    var body: some View {
        let colors = look?.displayColors(dark: scheme == .dark) ?? [tint]
        ZStack {
            if isPrivate { Ink.privateGlass }
            else { LinearGradient(colors: colors.map { Color(rgb: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing) }
            if isPrivate { Glyph(.incognito, size: size * 0.55, color: Ink.onDark) }
            else { Text(emoji).font(.system(size: size * 0.55)) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.27))
            .accessibilityHidden(true)
    }
}

struct SpaceEmojiPicker: View {
    @Binding var search: String
    let selected: String
    let pick: (String) -> Void
    private static let choices: [(String, String)] = [
        ("🌐", "globe world web"), ("🏠", "home personal"), ("💼", "work briefcase"), ("📚", "books reading"),
        ("🎨", "art color design"), ("🌱", "plant green garden"), ("☕️", "coffee"), ("🎵", "music"),
        ("🧪", "science test"), ("🔭", "explore telescope"), ("🧳", "travel luggage"), ("🏖️", "beach holiday"),
        ("🍳", "cooking food"), ("🚲", "bike sport"), ("🐈", "cat animal"), ("🌙", "moon night"),
        ("⭐️", "star symbol"), ("❤️", "heart love symbol"), ("⚙️", "gear settings symbol"), ("🔖", "bookmark symbol")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.SpaceTray.sectionGap) {
            TextField("Search emoji and symbols", text: $search).font(.body).frame(minHeight: Metrics.touch)
                .padding(Metrics.SpaceTray.side).background(Ink.card, in: Capsule()).accessibilityIdentifier("column.tray.emoji.search")
            Text(search.isEmpty ? "Suggested" : "Results").font(.headline).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.touch))], spacing: Metrics.SpaceTray.inset) {
                ForEach(Self.choices.filter { search.isEmpty || $0.1.localizedCaseInsensitiveContains(search) || $0.0 == search }, id: \.0) { emoji, words in
                    Button { pick(emoji) } label: {
                        Text(emoji).font(.title2).frame(minWidth: Metrics.touch, minHeight: Metrics.touch)
                            .background(selected == emoji ? Ink.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Metrics.SpaceTray.inset))
                    }.buttonStyle(.plain).accessibilityLabel(words).accessibilityValue(selected == emoji ? "selected" : "")
                        .accessibilityIdentifier("column.tray.emoji.pick.\(emoji)")
                }
            }
            Text("You can also enter an emoji with the keyboard.").font(.caption).foregroundStyle(Ink.secondary)
            TextField("Your emoji", text: Binding(get: { selected }, set: { value in if let first = value.first { pick(String(first)) } }))
                .font(.title2).frame(minHeight: Metrics.touch).accessibilityIdentifier("column.tray.emoji.custom")
        }
    }
}
