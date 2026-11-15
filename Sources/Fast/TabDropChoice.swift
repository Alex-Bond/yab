import AppKit
import SwiftUI

/// Shared by the column and the top strip. The folder clock starts anew
/// whenever the hand enters the left half, independently of the reveal.
struct TabDropChoice: Equatable {
    enum Side: Equatable { case folder, split }
    static let revealDelay: TimeInterval = 0.18
    static let folderHold: TimeInterval = 0.5
    var target: Tab.ID
    var side: Side
    var canSplit: Bool
    var count = 2
    var revealed = false
    var fill: CGFloat = 0
    var ready = false
}

/// The row under the hand: New Folder's mark at its start, Split View's at
/// its end, and between them the name of the one under the hand, the
/// mark of that one on a plate. Its name fits
/// the narrowest column, as two names side by side did not.
struct TabDropChoices: View {
    let choice: TabDropChoice
    var iconsOnly = false
    @Environment(\.tone) private var tone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var folderShown = false

    /// The names trade places as the hand crosses the middle: the old one
    /// up and out, the new one up from under it.
    private static let swap = Animation.timingCurve(0.33, 1, 0.68, 1, duration: 0.2)

    var body: some View {
        Group {
            if choice.ready {
                HStack(spacing: SideBar.markGap) {
                    FolderCreationMark()
                    Text("New Folder").font(.system(size: 14, weight: .medium)).lineLimit(1) // design: matches the approved prototype folder row typography
                        .opacity(folderShown || reduceMotion ? 1 : 0)
                        .offset(y: folderShown || reduceMotion ? 0 : 6)
                    Spacer(minLength: 0)
                    if !iconsOnly { Text("\(choice.count)").font(.system(size: 13)).foregroundStyle(.secondary) }
                }.padding(.horizontal, 10)
            } else {
                GeometryReader { geo in
                    // A pair's chip, 28 inside a 36 row; a compact row's 20.
                    let plate = min(28, geo.size.height - 8) // design: the pair chip's height inside the row's 4 inset
                    HStack(spacing: 4) {
                        mark(.folder, icon: "yab.folder.plus", plate: plate)
                        Group {
                            if iconsOnly { Color.clear } else { ViewThatFits(in: .horizontal) { name; Color.clear } }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        if choice.canSplit { mark(.split, icon: "rectangle.split.2x1", plate: plate) }
                    }
                    .padding(4)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .background(alignment: .leading) { hold(width: geo.size.width) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.wash(on: tone), in: RoundedRectangle(cornerRadius: SideBar.radius))
        .allowsHitTesting(false)
        .onAppear { showFolder() }
        .onChange(of: choice.ready) { _, _ in showFolder() }
    }

    private func showFolder() {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) { folderShown = choice.ready }
    }

    /// What letting go here does, in words.
    private var name: some View {
        let split = choice.side == .split
        return ZStack {
            Text("New Folder").opacity(split ? 0 : 1).offset(y: split ? -6 : 0)
            if choice.canSplit { Text("Split View").opacity(split ? 1 : 0).offset(y: split ? 0 : 6) }
        }
        .font(.system(size: 13.5, weight: .medium)) // design: matches the approved prototype choice label
        .foregroundStyle(Palette.strong(on: tone))
        .lineLimit(1)
        .fixedSize()
        .animation(reduceMotion ? nil : Self.swap, value: choice.side)
    }

    /// One end's mark: on a plate while the hand is on its half.
    private func mark(_ side: TabDropChoice.Side, icon: String, plate: CGFloat) -> some View {
        let on = choice.side == side
        return Symbol(icon, size: 16)
            .foregroundStyle(Palette.strong(on: tone).opacity(on ? 1 : 0.45))
            .frame(width: plate, height: plate)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous) // design: matches the approved prototype inset choice corners
                    .fill(Palette.strong(on: tone).opacity(on ? 0.17 : 0))
            )
            .animation(reduceMotion ? nil : Self.swap, value: choice.side)
    }

    /// The hold on New Folder: the whole row fills from its start.
    private func hold(width: CGFloat) -> some View {
        Rectangle().fill(Palette.strong(on: tone).opacity(0.08))
            .frame(width: width * (choice.side == .folder ? choice.fill : 0))
            .animation(.linear(duration: choice.fill == 1 ? TabDropChoice.folderHold : 0), value: choice.fill)
            .transaction { $0.disablesAnimations = false }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: SideBar.radius))
    }
}

/// Starts with the closed ordinary folder and opens through FaceView's
/// existing corner projection. Agent eyes are never part of this mark.
private struct FolderCreationMark: View {
    @Environment(\.tone) private var tone
    var body: some View {
        Face(pose: .seen, size: 21, tint: Palette.strong(on: tone), folder: true,
             unfolded: true, creating: true, weight: SideBar.folderWeight)
            .frame(width: 16, height: 16)
    }
}
