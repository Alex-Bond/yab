import SwiftUI

/// A small notice leaves through the edge it came from. Only a vertical
/// pull counts; buttons still receive ordinary clicks and horizontal moves.
enum NoticeEdge {
    case top, bottom

    var direction: CGFloat { self == .top ? -1 : 1 }
}

struct NoticeFling: ViewModifier {
    let edge: NoticeEdge
    let token: String
    let dismiss: () -> Void

    @State private var travel: CGFloat = 0
    @State private var leaving = false
    @State private var pending: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) private var still

    func body(content: Content) -> some View {
        content
            .offset(y: still ? 0 : edge.direction * travel)
            .opacity(leaving ? 0 : 1 - min(travel / 160, 0.4))
            .simultaneousGesture(drag)
            .onChange(of: token) { _, _ in reset() }
            .onDisappear { pending?.cancel() }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !leaving else { return }
                let toward = value.translation.height * edge.direction
                guard toward > 0, toward > abs(value.translation.width) * 1.2 else { return }
                travel = min(toward, 90)
            }
            .onEnded { value in
                let toward = value.translation.height * edge.direction
                let predicted = value.predictedEndTranslation.height * edge.direction
                guard toward > abs(value.translation.width) * 1.2,
                      toward > 34 || predicted > 80 else {
                    withAnimation(Motion.quick) { travel = 0 }
                    return
                }
                withAnimation(still ? Motion.quick : Motion.depart) {
                    travel = 90
                    leaving = true
                }
                let work = DispatchWorkItem {
                    pending = nil
                    dismiss()
                    reset()
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
    }

    private func reset() {
        pending?.cancel()
        pending = nil
        var quiet = Transaction()
        quiet.disablesAnimations = true
        withTransaction(quiet) { travel = 0; leaving = false }
    }
}

extension View {
    func noticeFling(_ edge: NoticeEdge, token: String, dismiss: @escaping () -> Void) -> some View {
        modifier(NoticeFling(edge: edge, token: token, dismiss: dismiss))
    }
}
