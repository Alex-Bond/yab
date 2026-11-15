import SwiftUI

/// Reload and stop, as Arc swaps them, measured frame by frame off two
/// recordings of Arc (four swaps, all alike): the glyph going shrinks to
/// 0.7 and is gone in about 35 ms; the one coming shows over the next 40 ms
/// and springs up from 0.7 past its size, about 4 % over at 0.1 s, settled
/// by 0.2 s. Arc's arrow is drawn a size above its cross, so this one is
/// too. A brief load keeps the arrow, avoiding a flash of the cross before
/// the page is ready.
struct Unwind: View {
    let stop: Bool
    var size: CGFloat = 11
    /// The door's ink at rest or under the pointer; held down, the glyph
    /// lights to the full ink, as Arc's does.
    var ink: Color = Palette.ink
    /// The arrow's square where its door draws reload smaller than `size`
    /// would, the cross in step under it; and the row's line weight.
    var arrowSide: CGFloat? = nil
    var stroke: CGFloat? = nil

    @State private var showingStop = false
    @Environment(\.accessibilityReduceMotion) private var still
    @Environment(\.doorPressed) private var pressed

    /// How small the glyph going ends and the one coming starts.
    private static let shrunk: CGFloat = 0.7
    /// Arc's arrow over its cross, side to side.
    private static let arrow: CGFloat = 1.12

    var body: some View {
        ZStack {
            glyph(Symbol("arrow.clockwise", size: size * Self.arrow, weight: .medium, side: arrowSide, stroke: stroke),
                  shown: !showingStop)
            glyph(Symbol("xmark", size: size, weight: .medium, side: arrowSide.map { ($0 / Self.arrow).rounded() }, stroke: stroke),
                  shown: showingStop)
        }
        .foregroundStyle(pressed ? Palette.ink : ink)
        .task(id: stop) {
            if stop {
                // In the reference the stop appears about half a second
                // after release, only if the page is still loading.
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            showingStop = stop
        }
    }

    /// The scale springs and the ink only fades, each on its own curve:
    /// the one going is quick and plain, the one coming waits for it.
    private func glyph(_ symbol: Symbol, shown: Bool) -> some View {
        symbol
            .scaleEffect(shown ? 1 : Self.shrunk)
            .animation(still ? nil : shown ? .spring(response: 0.15, dampingFraction: 0.55).delay(0.03) : .easeIn(duration: 0.035), value: shown)
            .opacity(shown ? 1 : 0)
            .animation(still ? nil : shown ? .easeOut(duration: 0.04).delay(0.03) : .easeIn(duration: 0.035), value: shown)
    }
}

private struct DoorPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// A door's pointer is down on it (Door.Give).
    var doorPressed: Bool {
        get { self[DoorPressedKey.self] }
        set { self[DoorPressedKey.self] = newValue }
    }
}
