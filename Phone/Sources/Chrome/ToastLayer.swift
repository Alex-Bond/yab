import SwiftUI

/// The one plate that says what happened when nothing on screen answers
/// ("Link copied"): under the status bar, centered, a glyph and a few words,
/// in from a little above and gone after 2.2 s.
struct ToastLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let toast = app.surfaces.toast
        let bottom = toast?.place == .bottom
        VStack(spacing: 0) {
            if bottom { Spacer(minLength: 0) }
            if let toast {
                ToastView(toast: toast, undo: toast.undoable ? { app.surfaces.undoToast(toast.id) } : nil)
                    .id(toast.id)
                    .transition(bottom ? .bottomToast : .toast)
            }
            if !bottom { Spacer(minLength: 0) }
        }
        .padding(.top, Metrics.Toast.top)
        .padding(.bottom, Metrics.Toast.bottom)
        .frame(maxWidth: .infinity)
        .ignoresSafeArea()
        // Only a toast with Undo takes a touch, and only on its plate.
        .allowsHitTesting(toast?.undoable == true)
    }
}

struct ToastView: View {
    let toast: Surfaces.Toast
    var undo: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: Metrics.Toast.gap) {
            Glyph(toast.glyph, size: Metrics.Toast.icon)
            Text(toast.text)
                .font(.system(size: Metrics.Toast.font, weight: .medium))
                .tracking(-0.01 * Metrics.Toast.font)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
            if let undo {
                Button("Undo", action: undo)
                    .font(.system(size: Metrics.Toast.font, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .systemBlue))
                    .padding(.horizontal, Metrics.Toast.undoPadding)
                    .frame(minWidth: Metrics.touch, minHeight: Metrics.Toast.height)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("chrome.toast.undo")
            }
        }
        .padding(.leading, Metrics.Toast.leading)
        .padding(.trailing, undo == nil ? Metrics.Toast.trailing : Metrics.Toast.undoTrailing)
        .frame(height: Metrics.Toast.height)
        .glassCapsule(interactive: false)
        .accessibilityElement(children: undo == nil ? .combine : .contain)
        .accessibilityIdentifier("chrome.toast")
        .accessibilityAddTraits(.updatesFrequently)
    }
}

extension Metrics.Toast {
    /// Undo after the words (the back stack's prototype): 10 each side of
    /// the word, the plate's end 6 past it.
    static let undoPadding: CGFloat = 10
    static let undoTrailing: CGFloat = 6
}

extension AnyTransition {
    /// At the bottom: up from a little below, and back down.
    static var bottomToast: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: Metrics.Toast.bottomRise)).animation(Motion.toastIn.animation),
            removal: .opacity.combined(with: .offset(y: Metrics.Toast.bottomRise)).animation(Motion.toastOut.animation)
        )
    }

    static var toast: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: -Metrics.Toast.rise)).animation(Motion.toastIn.animation),
            removal: .opacity.combined(with: .offset(y: -Metrics.Toast.rise)).animation(Motion.toastOut.animation)
        )
    }
}
