import SwiftUI

/// While voice search listens (the right button's Voice Search), the lit
/// microphone before the eyes: white on ink, a tap on it is Return, and the
/// field says "Listening…" until words come. Otherwise nothing: New Tab's
/// field keeps its own look (the magnifier, "Search, ask or give a task",
/// the eyes, ✕ beside it).
struct FieldInputOptions: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let voice = app.voice
        let mic = voice.shows(in: app.field)
        HStack(spacing: 0) {
            if mic {
                Button { voice.toggle() } label: {
                    Glyph(.microphone, size: Metrics.Field.optionGlyph, color: Ink.onNewAnswer)
                        .frame(width: Metrics.Field.optionLit, height: Metrics.Field.optionLit)
                        .background(Ink.newAnswer, in: Circle())
                        .frame(width: Metrics.Field.option, height: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("field.voice")
                .accessibilityLabel("Stop Listening")
                .accessibilityValue("listening")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(Motion.disabled ? nil : Motion.eyesWord.animation, value: mic)
        // The field going (a choice, ✕, a swipe down) stops listening.
        .onDisappear { app.voice.cancel() }
    }
}

extension Metrics.Field {
    /// The lit microphone: 20 to see on a 30 ink circle, in a 34 wide column.
    static let optionGlyph: CGFloat = 20
    static let option: CGFloat = 34
    static let optionLit: CGFloat = 30
}
