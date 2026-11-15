import SwiftUI
import UIKit
import SyncKit

/// The Mac and iPhone compile the same catalog. UIKit owns the local choice.
typealias PhoneAppIcon = AppIconCatalog

extension AppIconCatalog {
    /// Flat and Original are layered Icon Composer icons.
    var layered: Bool { self == .original || self == .flat }
    var themeNote: String { layered ? "Follows Dark, Tinted and Clear" : "Dark and Tinted are made by iOS" }
    static func current(_ alternateName: String?) -> Self? {
        if alternateName == "YabFlat" { return .flat }
        if let alternateName, charmAlternates.contains(alternateName) { return .charm }
        return allCases.first { $0.alternateName == alternateName }
    }
    @MainActor
    func picture(dark: Bool, installedName: String? = nil) -> UIImage? {
        let name: String
        if self == .charm, let installedName, let installedPreview = Self.installedCharmPreview(installedName) {
            name = installedPreview
        } else {
            name = SettingsStore.shared.appIcons.previewName(for: self)
        }
        // Only the bitmap: the asset's image would follow the screen's appearance
        // again when drawn, and the Light/Dark choice is about the icon alone.
        let image = UIImage(named: name, in: .main, compatibleWith: UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        return image?.cgImage.map { UIImage(cgImage: $0, scale: image?.scale ?? 1, orientation: .up) } ?? image
    }

    static func installedCharmPreview(_ name: String) -> String? {
        for left in charmColors {
            for right in charmColors + ["silver"] where charmAlternateName(left: left, right: right) == name {
                return charmPreviewName(left: left, right: right)
            }
        }
        return nil
    }
}

extension Haptics.Reason {
    static let appIconFailed = "icon failed"    // error: iOS refused the icon
    static let appIconEnd = "icon end"          // soft: Cover Flow pushed past its first or last icon
}

@MainActor
@Observable
final class AppIconSelection {
    static let shared = AppIconSelection()
    private(set) var currentName: String? = UIApplication.shared.alternateIconName
    private(set) var changing = false
    private(set) var error: String?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var presentation: UUID?

    static let failure = "Couldn't change the icon. Try again."

    var title: String { PhoneAppIcon.current(currentName)?.title ?? "System icon" }
    var supported: Bool { UIApplication.shared.supportsAlternateIcons }
    func refresh() {
        currentName = UIApplication.shared.alternateIconName
        SettingsStore.shared.appIcons.keepLegacySelection(PhoneAppIcon.current(currentName))
    }
    func clearError() { error = nil }
    func present(_ id: UUID) { presentation = id; refresh(); clearError() }
    func retire(_ id: UUID) { if presentation == id { presentation = nil } }
    func isCurrentPresentation(_ id: UUID) -> Bool {
        presentation == id && Self.onPage && UIApplication.shared.applicationState == .active
    }
    func inUse(_ icon: PhoneAppIcon) -> Bool {
        if icon == .charm { return currentName == SettingsStore.shared.appIcons.nativeName(for: icon) }
        return PhoneAppIcon.current(currentName) == icon
    }

    /// Named states only: the button's other words, without asking iOS.
    func stage(changing: Bool = false, error: String? = nil) {
        self.changing = changing
        self.error = error
    }

    /// Settings shows the App Icon page in front.
    private static var onPage: Bool {
        let ui = SettingsUI.shared
        return ui.sheet.presented && ui.navigation.last == .page(.appIcon)
    }

    /// The only effect is Apple's native icon request, one per choice: iOS
    /// says so in its own alert. A late completion still reads its actual
    /// outcome, but never reports an error on a different page.
    func choose(_ icon: PhoneAppIcon, from owner: UUID) {
        guard presentation == owner, Self.onPage,
              UIApplication.shared.applicationState == .active, supported, !changing,
              SettingsStore.shared.appIcons.unlocked(icon) else { return }
        refresh()
        guard !inUse(icon) else { return }
        let id = UUID()
        request = id; changing = true; error = nil
        Haptics.play(.light, reason: Haptics.Reason.appIconUse)
        let nativeName = SettingsStore.shared.appIcons.nativeName(for: icon)
        UIApplication.shared.setAlternateIconName(nativeName) { [weak self] failure in
            Task { @MainActor in
                guard let self, self.request == id else { return }
                self.request = nil; self.changing = false; self.refresh()
                if failure == nil, self.currentName == nativeName {
                    SettingsStore.shared.appIcons.remember(icon)
                }
                guard self.presentation == owner, Self.onPage else { return }
                if failure != nil || self.currentName != nativeName {
                    self.error = Self.failure
                    Haptics.play(.error, reason: Haptics.Reason.appIconFailed)
                }
            }
        }
    }
}

/// App Icon, a page of its own: the Mac's Cover Flow (AppIcons.swift's
/// AppIconPage: the icon in front 180, its neighbors turned 50° and at
/// 0.66, the edges fading), the icon's name and how it follows the theme,
/// dots, a Light/Dark preview, and one button that applies it: Use This
/// Icon, Changing…, In Use. Browsing has no system effect.
struct AppIconPickerView: View {
    private typealias C = Metrics.Settings.AppIcon
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var presentationID = UUID()
    @State private var preview = PhoneAppIcon.flat
    @State private var previewDark: Bool?
    @State private var dragFrom: Int?
    @State private var shift: CGFloat = 0
    @State private var bumped = false
    private var selection: AppIconSelection { .shared }
    private var access: AppIconAccess { SettingsStore.shared.appIcons }
    private var choices: [PhoneAppIcon] { PhoneAppIcon.allCases.filter { access.visible($0) } }
    private var index: Int { choices.firstIndex(of: preview) ?? 0 }
    private var reduced: Bool { reduceMotion || Motion.reduced }
    private var dark: Bool { previewDark ?? (colorScheme == .dark) }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Text("How Yab looks on your Home Screen. Icons you unlock on your Mac are available here too.")
                    .font(.subheadline).foregroundStyle(SettingsInk.footer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, C.lineSide)
                    .padding(.top, C.lineTop)
                    .accessibilityIdentifier("settings.appIcon.line")
                flow
                    .padding(.top, C.flowTop)
                Text(preview.title).font(.title3.weight(.semibold)).foregroundStyle(SettingsInk.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, C.nameTop)
                    .accessibilityIdentifier("settings.appIcon.preview.title")
                Text(preview.themeNote).font(.footnote).foregroundStyle(SettingsInk.footer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, C.noteTop)
                    .accessibilityIdentifier("settings.appIcon.note")
                if !access.unlocked(preview), let friends = preview.friendCount {
                    Text("Comes with \(friends) \(friends == 1 ? "friend" : "friends"). Unlock it on your Mac.")
                        .font(.footnote).foregroundStyle(SettingsInk.footer)
                        .multilineTextAlignment(.center)
                        .padding(.top, C.noteTop)
                        .accessibilityIdentifier("settings.appIcon.locked")
                } else if !access.unlocked(preview), preview == .charm {
                    Text("Comes with a best friend. Unlock it on your Mac.")
                        .font(.footnote).foregroundStyle(SettingsInk.footer)
                        .multilineTextAlignment(.center)
                        .padding(.top, C.noteTop)
                        .accessibilityIdentifier("settings.appIcon.locked")
                }
                dots
                    .padding(.top, C.dotsTop)
                theme
                    .padding(.top, C.themeTop)
                if !selection.supported {
                    Text("This installation doesn't support alternate app icons.")
                        .font(.footnote).foregroundStyle(SettingsInk.footer)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, C.noteTop)
                        .accessibilityIdentifier("settings.appIcon.unavailable")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, C.bottomRoom)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) { use }
        .background(SettingsInk.pageGround).foregroundStyle(SettingsInk.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.page.appIcon")
        .onAppear {
            selection.present(presentationID)
            let ui = SettingsUI.shared
            preview = ui.appIconPreview ?? PhoneAppIcon.current(selection.currentName) ?? .flat
            if !choices.contains(preview) { preview = .flat }
            if let dark = ui.appIconPreviewDark { previewDark = dark }
        }
        .onDisappear { selection.retire(presentationID) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { selection.refresh() } }
        .onChange(of: reduced) { _, _ in dragFrom = nil; shift = 0 }
        .onChange(of: choices) { _, available in
            if !available.contains(preview) { preview = .flat }
            dragFrom = nil; shift = 0
        }
    }

    // MARK: - Cover Flow

    private var flow: some View {
        GeometryReader { geometry in
            let side = C.artworkSide
            ZStack {
                ForEach(Array(choices.enumerated()), id: \.element) { offset, icon in
                    let away = CGFloat(offset - index) - shift
                    let distance = abs(away)
                    let near = min(distance, 1)
                    let direction: CGFloat = away < 0 ? -1 : 1
                    if let picture = icon.picture(dark: dark) {
                        Image(uiImage: picture).resizable().interpolation(.high)
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: side * C.artworkRadius, style: .continuous))
                            .shadow(color: .black.opacity(C.shadowOpacity), radius: C.shadowRadius, y: C.shadowY)
                            .rotation3DEffect(.degrees(reduced ? 0 : -direction * C.turnDegrees * near),
                                              axis: (x: 0, y: 1, z: 0), perspective: C.perspective)
                            .scaleEffect(reduced ? 1 : 1 - C.neighborShrink * near)
                            .offset(x: reduced ? 0 : direction * (side * C.neighborOffset * near + max(0, distance - 1) * side * C.farOffset))
                            .opacity(reduced ? (icon == preview ? 1 : 0) : distance > C.visibleNeighbors ? 0 : 1)
                            .zIndex(-Double(distance))
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .frame(width: geometry.size.width, height: side)
            .padding(.top, C.artworkTop)
            .frame(width: geometry.size.width, height: C.flowHeight, alignment: .top)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: C.fadeEdge),
                                         .init(color: .black, location: 1 - C.fadeEdge), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            .contentShape(Rectangle())
            .simultaneousGesture(drag(stride: side * C.dragStride))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("App icon preview")
            .accessibilityValue(preview.title)
            .accessibilityAdjustableAction { direction in step(direction == .increment ? 1 : -1) }
            .accessibilityIdentifier("settings.appIcon.gallery")
            .overlay(alignment: .top) { neighbors(width: geometry.size.width, side: side) }
        }.frame(height: C.flowHeight)
    }

    /// The icons beside the one in front are tapped to come forward, as on
    /// the Mac: one real target each side, as large as the picture's room.
    private func neighbors(width: CGFloat, side: CGFloat) -> some View {
        let zone = max(Metrics.touch, (width - side) / 2)
        return HStack(spacing: 0) {
            neighbor(-1, size: CGSize(width: zone, height: side))
            Spacer(minLength: 0)
            neighbor(1, size: CGSize(width: zone, height: side))
        }
        .frame(width: width, height: side)
        .padding(.top, C.artworkTop)
    }

    @ViewBuilder
    private func neighbor(_ direction: Int, size: CGSize) -> some View {
        let next = index + direction
        if choices.indices.contains(next) {
            Button { step(direction) } label: {
                Color.clear.frame(width: size.width, height: size.height).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(selection.changing)
            .accessibilityLabel(choices[next].title)
            .accessibilityHint(direction < 0 ? "Shows the previous icon" : "Shows the next icon")
            .accessibilityIdentifier(direction < 0 ? "settings.appIcon.previous" : "settings.appIcon.next")
        } else {
            Color.clear.frame(width: size.width, height: size.height).allowsHitTesting(false)
        }
    }

    /// One dot per icon, the one in front in ink, as the Mac's.
    private var dots: some View {
        HStack(spacing: C.dotGap) {
            ForEach(choices) { icon in
                Circle().fill(icon == preview ? SettingsInk.text : SettingsInk.value.opacity(C.dotOff))
                    .frame(width: C.dot, height: C.dot)
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: - the Light/Dark preview

    private var theme: some View {
        HStack(spacing: 0) {
            themeChoice("Light", dark: false)
            themeChoice("Dark", dark: true)
        }
        .frame(width: C.themeWidth, height: C.themeHeight)
        .background(alignment: dark ? .trailing : .leading) {
            Capsule().fill(SettingsInk.knob)
                .shadow(color: .black.opacity(C.knobShadow), radius: 1.5, y: 1)
                .frame(width: C.themeWidth / 2 - C.themeInset, height: C.themeHeight - C.themeInset * 2)
                .padding(.horizontal, C.themeInset)
        }
        .background(SettingsInk.iconBox, in: Capsule())
        .frame(height: Metrics.touch)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.appIcon.theme")
    }

    private func themeChoice(_ words: String, dark choice: Bool) -> some View {
        Button {
            guard dark != choice else { return }
            Motion.appIconTheme.run { previewDark = choice }
        } label: {
            Text(words).font(.subheadline.weight(.semibold)).foregroundStyle(SettingsInk.text)
                .frame(maxWidth: .infinity, minHeight: Metrics.touch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: C.themeHeight)
        .accessibilityAddTraits(dark == choice ? .isSelected : [])
        .accessibilityIdentifier("settings.appIcon.theme." + words.lowercased())
    }

    // MARK: - Use This Icon

    private enum UseState { case use, changing, inUse, locked }

    private var useState: UseState {
        if selection.changing { return .changing }
        if !access.unlocked(preview) { return .locked }
        return selection.inUse(preview) ? .inUse : .use
    }

    private var use: some View {
        let state = useState
        return VStack(spacing: C.errorGap) {
            if let error = selection.error {
                Text(error).font(.footnote).foregroundStyle(SettingsInk.footer)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.appIcon.error")
            }
            Button {
                selection.choose(preview, from: presentationID)
            } label: {
                HStack(spacing: C.checkGap) {
                    if state == .inUse { Glyph(.checkmark1Small, size: C.check, color: SettingsInk.text) }
                    Text(state == .changing ? "Changing…" : state == .inUse ? "In Use" : state == .locked ? "Locked" : "Use This Icon")
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(state == .use ? SettingsInk.onInk : SettingsInk.text)
                .frame(maxWidth: .infinity, minHeight: C.button)
                .background(state == .use ? SettingsInk.ink : SettingsInk.iconBox, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(AppIconUseStyle())
            .disabled(!selection.supported || state != .use)
            .accessibilityIdentifier("settings.appIcon.use")
        }
        .padding(.horizontal, C.buttonSide)
        .padding(.top, C.errorGap)
        .padding(.bottom, C.buttonBottom)
        .background(SettingsInk.pageGround)
    }

    // MARK: - browsing

    /// User actions reach this path; restoration and native readback do not.
    private func browse(_ icon: PhoneAppIcon) {
        guard selection.isCurrentPresentation(presentationID), !selection.changing, icon != preview else { return }
        selection.clearError()
        Haptics.play(.selection, reason: Haptics.Reason.appIconPreview)
        Motion.appIconTurn.run { preview = icon; shift = 0 }
    }

    private func step(_ direction: Int) {
        guard !selection.changing else { return }
        let next = min(max(index + direction, 0), choices.count - 1)
        guard next != index else { return }
        browse(choices[next])
    }

    private func drag(stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: C.dragMinimum)
            .onChanged { value in
                guard selection.isCurrentPresentation(presentationID), !selection.changing,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                let origin = dragFrom ?? index
                if dragFrom == nil { bumped = false }
                dragFrom = origin
                let moved = -value.translation.width / stride
                let wanted = origin + Int(moved.rounded())
                let next = min(max(wanted, 0), choices.count - 1)
                var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
                let changed = preview != choices[next]
                if changed { selection.clearError() }
                withTransaction(transaction) {
                    preview = choices[next]
                    shift = reduced ? 0 : min(max(moved - CGFloat(next - origin), -C.edgeShift), C.edgeShift)
                }
                if changed { Haptics.play(.selection, reason: Haptics.Reason.appIconPreview) }
                // Past the first or the last: one soft "no" per drag.
                if wanted != next, !bumped {
                    bumped = true
                    Haptics.play(.soft, reason: Haptics.Reason.appIconEnd)
                }
            }
            .onEnded { value in
                guard let origin = dragFrom else { return }
                dragFrom = nil
                guard selection.isCurrentPresentation(presentationID), !selection.changing else { shift = 0; return }
                let moved = -value.predictedEndTranslation.width / stride
                let next = min(max(origin + Int(moved.rounded()), 0), choices.count - 1)
                if preview == choices[next] {
                    Motion.appIconTurn.run { shift = 0 }
                } else {
                    browse(choices[next])
                }
            }
    }
}

/// The button keeps its words in ink while it says Changing… or In Use: a
/// state, not a grayed-out control. Pressed, it dims a little.
private struct AppIconUseStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
