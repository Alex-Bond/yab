import SwiftUI
import UIKit

/// What the key's card holds: the code on eight keycaps that fly out of the
/// key, and the Recovery Key's fourteen groups of four. Laid out in the
/// card's own 370-point width (FirstRunView's ChainGeo).

// MARK: - the code

struct CodeCard: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let s = space.s
        let code = currentCode
        let letters = Array(code.filter { $0 != "-" })
        let online = NetworkWatch.shared.isOnline
        ZStack(alignment: .topLeading) {
            CopyPill(text: code, space: space)
                .opacity(run.accepted ? 0 : 1)
                .animation(FirstRun.motion(.easeOut(duration: 0.2)), value: run.accepted)
                .frame(width: ChainGeo.codeCard.w * s, alignment: .trailing)
                .padding(.top, 14 * s)
                .offset(x: -14 * s)
            VStack(spacing: 10 * s) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 10 * s) {
                        ForEach(0..<4, id: \.self) { col in
                            let i = row * 4 + col
                            Keycap(letter: i < letters.count ? letters[i] : " ", index: i, space: space,
                                   done: run.accepted, quiet: !online && !run.accepted, flies: run.capsFly, flips: run.flips)
                        }
                    }
                }
            }
            .offset(x: 22 * s, y: 62 * s)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(run.accepted ? "\(FirstRun.macName(app)) joined" : letters.map { String($0) }.joined(separator: " "))
            .accessibilityIdentifier("welcome.code")
            CodeFoot(space: space, online: online)
                .frame(width: ChainGeo.codeCard.w * s, height: 28 * s)
                .offset(y: 288 * s)
        }
        .frame(width: ChainGeo.codeCard.w * s, height: ChainGeo.codeCard.h * s, alignment: .topLeading)
        .onChange(of: code) { _, _ in run.codeRenewed() }
    }

    private var currentCode: String {
        if case let .joining(.code(code)) = app.sync.phase { return code }
        return FirstRun.standInCode
    }
}

/// One keycap: out of the key on the way in, black and hopping when the Mac
/// lets the code in, flipped like a split-flap board on a new code.
private struct Keycap: View {
    let letter: Character
    let index: Int
    let space: ChainSpace
    let done: Bool
    /// No line: the keys go pale, their letters still legible.
    let quiet: Bool
    let flies: Bool
    let flips: Int
    @Environment(\.colorScheme) private var scheme
    @State private var out = false
    @State private var shown: Character?

    var body: some View {
        let s = space.s
        let col = CGFloat(index % 4), row = CGFloat(index / 4)
        let colors = FirstRunInk.cap(scheme, done: done)
        let shape = RoundedRectangle(cornerRadius: 18 * s, style: .continuous)
        Text(String(shown ?? letter))
            .font(.system(size: 44 * s, weight: .bold, design: .monospaced))
            .foregroundStyle(colors.letter)
            .frame(width: 74 * s, height: 100 * s)
            .background(colors.fill, in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(done ? 0 : 0.07), lineWidth: 1))
            .shadow(color: .black.opacity(done ? 0 : 0.08), radius: 5 * s, y: 4 * s)
            .animation(FirstRun.motion(.easeOut(duration: 0.05).delay(Double(index) * 0.045)), value: done)
            .opacity(quiet ? 0.4 : 1)
            .animation(FirstRun.motion(.easeOut(duration: 0.3)), value: quiet)
            .keyframeAnimator(initialValue: 0.0, trigger: done) { view, lift in
                view.offset(y: lift * s)
            } keyframes: { _ in
                LinearKeyframe(0, duration: Double(index) * 0.045 + 0.001)
                CubicKeyframe(-12, duration: 0.11)
                SpringKeyframe(0, duration: 0.18, spring: Spring(response: 0.2, dampingRatio: 0.55))
            }
            .keyframeAnimator(initialValue: 0.0, trigger: flips) { view, angle in
                view.rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
            } keyframes: { _ in
                LinearKeyframe(0, duration: Double(index) * 0.045 + 0.001)
                CubicKeyframe(90, duration: 0.13)
                LinearKeyframe(-90, duration: 0.001)
                SpringKeyframe(0, duration: 0.22, spring: Spring(response: 0.22, dampingRatio: 0.6))
            }
            // Out of the key in the card's corner, one by one.
            .scaleEffect(out ? 1 : 0.3)
            .rotationEffect(.degrees(out ? 0 : (index % 2 == 1 ? 24 : -24)))
            .offset(x: out ? 0 : -(col * 84 + 40) * s, y: out ? 0 : -(row * 110 + 40) * s)
            .opacity(out ? 1 : 0)
            .onAppear {
                if flies, let a = FirstRun.travel(.spring(response: 0.43, dampingFraction: 0.6).delay(0.11 + Double(index) * 0.026)) {
                    withAnimation(a) { out = true }
                } else {
                    withAnimation(FirstRun.motion(.easeOut(duration: 0.2).delay(0.08))) { out = true }
                }
            }
            .onChange(of: letter) { old, new in
                // The new letter shows when the key has turned edge on.
                guard !Motion.disabled else { shown = nil; return }
                shown = old
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.045 + 0.13) { shown = nil }
            }
    }
}

/// Under the keys: the next code's countdown, no line, a new code, joined.
private struct CodeFoot: View {
    let space: ChainSpace
    let online: Bool
    @Environment(AppModel.self) private var app
    private var run: FirstRun { .shared }

    var body: some View {
        let s = space.s
        HStack(spacing: 8 * s) {
            if run.accepted {
                Text("\(FirstRun.macName(app)) joined")
            } else if !online {
                Circle().fill(Color(red: 1, green: 0.62, blue: 0.04)).frame(width: 8 * s, height: 8 * s)
                Text("No connection. Yab keeps trying.")
            } else if run.renewedNote {
                Text("New code. The old one expired.")
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, 600 - Int(context.date.timeIntervalSince(run.codeSince)))
                    HStack(spacing: 8 * s) {
                        ZStack {
                            Circle().stroke(Color.primary.opacity(0.12), lineWidth: 2 * s)
                            Circle().trim(from: 0, to: CGFloat(left) / 600)
                                .stroke(Color(red: 0.04, green: 0.52, blue: 1), style: StrokeStyle(lineWidth: 2 * s, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        .frame(width: 13 * s, height: 13 * s)
                        Text("New code in \(left / 60):\(String(format: "%02d", left % 60))")
                            .monospacedDigit()
                    }
                }
            }
        }
        .font(space.font(14.5, .regular, cap: 1.3))
        .foregroundStyle(SettingsInk.footer)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity)
        .transition(.opacity)
        .animation(FirstRun.motion(.easeOut(duration: 0.18)), value: run.accepted)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("welcome.caption")
    }
}

/// Copy → Copied, back after two seconds.
private struct CopyPill: View {
    let text: String
    let space: ChainSpace
    @State private var copied = false

    var body: some View {
        let s = space.s
        Button {
            UIPasteboard.general.string = text
            Haptics.play(.soft, reason: Haptics.Reason.copyLink)
            withAnimation(FirstRun.motion(.easeOut(duration: 0.2))) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(FirstRun.motion(.easeOut(duration: 0.2))) { copied = false } }
        } label: {
            HStack(spacing: 6 * s) {
                Glyph(.clipboard, size: 16 * s, color: Ink.primary)
                Text(copied ? "Copied" : "Copy")
                    .contentTransition(.opacity)
            }
            .font(.system(size: 14 * s, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .padding(.leading, 11 * s)
            .padding(.trailing, 14 * s)
            .frame(height: 34 * s)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(copied ? "Copied" : "Copy")
        .accessibilityIdentifier("welcome.copy")
    }
}

// MARK: - the Recovery Key

/// The Recovery Key in the same card, a new height: fourteen groups of four
/// (Seal.recovery: 34 bytes of base32), filled by Paste or by typing.
struct RecoveryCard: View {
    let space: ChainSpace
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    private var run: FirstRun { .shared }

    static let groups = 14

    var body: some View {
        @Bindable var sync = app.sync
        let s = space.s
        let parts = Self.parts(sync.typed)
        let wrong = sync.phase == .joining(.recovery(wrong: true)) && !sync.typed.isEmpty
        let cell = (ChainGeo.recoveryCard.w - 44 - 3 * 8) / 4
        ZStack(alignment: .topLeading) {
            // The keyboard's way in: out of sight, it holds what is typed.
            TextField("", text: $sync.typed)
                .keyboardType(.asciiCapable)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.join)
                .focused($focused)
                .onSubmit { run.tryRecovery(app) }
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .accessibilityIdentifier("welcome.field")
            VStack(alignment: .leading, spacing: 8 * s) {
                ForEach(0..<4, id: \.self) { row in
                    HStack(spacing: 8 * s) {
                        ForEach(0..<4, id: \.self) { col in
                            let i = row * 4 + col
                            if i < Self.groups {
                                KeyGroup(text: i < parts.count ? parts[i] : nil, index: i, space: space,
                                         caret: focused && i == min(Self.groups - 1, Self.caret(parts)),
                                         bad: wrong && i == max(0, parts.count - 1), done: run.accepted, typing: focused)
                                    .frame(width: cell * s, height: 52 * s)
                            }
                        }
                    }
                }
            }
            .modifier(ChainShake(travel: CGFloat(run.wrongs)))
            .animation(FirstRun.motion(.linear(duration: 0.38)), value: run.wrongs)
            .offset(x: 22 * s, y: 62 * s)
            .contentShape(Rectangle())
            .onTapGesture { if !run.accepted { focused = true } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.isEmpty ? "Recovery Key, empty" : "Recovery Key, \(parts.count) of \(Self.groups) groups")
            .accessibilityIdentifier("welcome.key")
            if parts.isEmpty && !focused && !run.accepted {
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.first ?? ""
                    Task { @MainActor in run.paste(text, app) }
                }
                .buttonBorderShape(.capsule)
                .labelStyle(.titleAndIcon)
                .tint(Ink.primary)
                .shadow(color: .black.opacity(0.18), radius: 9 * s, y: 6 * s)
                // In the hole the fourteenth group leaves on the last line.
                .frame(width: cell * 2 * s + 8 * s, height: 52 * s)
                .offset(x: (22 + 2 * (cell + 8)) * s, y: (62 + 3 * 60) * s)
                .transition(.opacity.combined(with: .scale(scale: 0.9)).animation(FirstRun.motion(.easeOut(duration: 0.12))))
                .accessibilityIdentifier("welcome.paste")
            }
        }
        .frame(width: ChainGeo.recoveryCard.w * s, height: ChainGeo.recoveryCard.h * s, alignment: .topLeading)
        .onChange(of: run.typing, initial: true) { _, now in if focused != now { focused = now } }
        .onChange(of: focused) { _, now in if run.typing != now { run.typing = now } }
    }

    /// What is typed, as the key's groups: letters and digits, four apiece.
    static func parts(_ typed: String) -> [String] {
        let letters = Array(typed.uppercased().filter { $0.isLetter || $0.isNumber })
        return stride(from: 0, to: min(letters.count, groups * 4), by: 4).map { String(letters[$0..<min($0 + 4, letters.count)]) }
    }

    /// The group the next letter goes into.
    static func caret(_ parts: [String]) -> Int {
        guard let last = parts.last else { return 0 }
        return last.count == 4 ? parts.count : parts.count - 1
    }
}

/// One group of four: dots while empty, the letters as they come.
private struct KeyGroup: View {
    let text: String?
    let index: Int
    let space: ChainSpace
    let caret: Bool
    let bad: Bool
    let done: Bool
    let typing: Bool
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = space.s
        let shape = RoundedRectangle(cornerRadius: 14 * s, style: .continuous)
        let caps = FirstRunInk.cap(scheme, done: done)
        HStack(spacing: 1) {
            if let text {
                Text(text)
                    .id(text.count == 4 ? text : "typing")
                    .transition(.opacity.combined(with: .offset(y: 6 * s))
                        .animation(FirstRun.motion(.easeOut(duration: 0.2).delay(typing ? 0 : 0.06 + Double(index) * 0.055))))
            } else if !caret {
                Text("\u{00B7}\u{00B7}\u{00B7}\u{00B7}").foregroundStyle(Color.primary.opacity(0.25))
            }
            if caret {
                Rectangle()
                    .fill(Color(red: 0.04, green: 0.52, blue: 1))
                    .frame(width: 2, height: 22 * s)
                    .phaseAnimator([1.0, 0.0]) { view, o in view.opacity(o) } animation: { _ in .linear(duration: 0.5).delay(0.5) }
            }
        }
        .font(.system(size: 21 * s, weight: .semibold, design: .monospaced))
        .tracking(1.5)
        .foregroundStyle(bad ? AppearanceColors.color(0xD70015, 0xFF6961) : caps.letter)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bad ? Color(red: 1, green: 0.27, blue: 0.23).opacity(scheme == .dark ? 0.22 : 0.12) : caps.fill, in: shape)
        .overlay(shape.strokeBorder(bad ? Color(red: 1, green: 0.27, blue: 0.23) : Color.primary.opacity(done ? 0 : 0.07), lineWidth: bad ? 1.5 : 1))
        .animation(FirstRun.motion(.easeOut(duration: 0.05).delay(Double(index) * 0.04)), value: done)
    }
}

/// ±10 sideways, fading out, once per wrong answer.
struct ChainShake: GeometryEffect {
    var travel: CGFloat
    var animatableData: CGFloat {
        get { travel }
        set { travel = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let q = travel - travel.rounded(.down)
        return ProjectionTransform(CGAffineTransform(translationX: 10 * sin(q * .pi * 6) * (1 - q), y: 0))
    }
}
