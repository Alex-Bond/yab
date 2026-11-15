import SwiftUI
import UIKit

/// What a pull from the left edge shows under the page (BackStack.swipe):
/// at a first page the tab that opened it, a card 0.92 of the screen on the
/// dark, its corners and its dark going as it grows to the whole screen
/// with the page's leaving; with nothing behind, the plain gray of a list's
/// end. The page itself moves in PageLayer; its shadow is cast from here, by
/// a shape under it, so the live page is never drawn with a shadow of its
/// own. The layer's host puts the edge's recognizer on the window.
struct BackRevealLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let stack = app.backStack
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let swipe = stack.swipe {
                    let pose = BackPose(swipe: swipe, width: geo.size.width)
                    switch swipe.kind {
                    case let .opener(id):
                        Ink.backGround.opacity(Double(1 - pose.progress))
                        if let tab = app.browser.tab(id) {
                            OpenerCard(tab: tab, pool: app.pages)
                                .frame(width: geo.size.width, height: geo.size.height)
                                .overlay(Color.black.opacity(pose.cardDim))
                                .clipShape(RoundedRectangle(cornerRadius: pose.cardRadius / pose.cardScale, style: .continuous))
                                .scaleEffect(pose.cardScale)
                        }
                    case .nothing:
                        Ink.backNothing
                    }
                    // The page's shadow on its left edge, cast by its own shape under it.
                    RoundedRectangle(cornerRadius: pose.pageRadius, style: .continuous)
                        .fill(Color.black)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .shadow(color: .black.opacity(Metrics.Back.shadowOpacity * Double(pose.shadow)),
                                radius: Metrics.Back.shadowRadius, x: Metrics.Back.shadowX * pose.shadow)
                        .offset(x: swipe.offset)
                        .opacity(pose.shadow > 0 ? 1 : 0)
                }
                BackGestureHost(gestures: stack.gestures)
                    .frame(width: 0, height: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { stack.width = geo.size.width }
            .onChange(of: geo.size.width) { stack.width = geo.size.width }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Where everything stands `offset` into a pull, the prototype's `renderBack`.
struct BackPose: Equatable {
    /// 0 as the finger lands, 1 with the page gone.
    let progress: CGFloat
    let cardScale: CGFloat
    let cardRadius: CGFloat
    let cardDim: Double
    /// The leaving page's own corners.
    let pageRadius: CGFloat
    /// How strong its shadow is, 0 to 1.
    let shadow: CGFloat

    init(swipe: BackSwipe, width: CGFloat) {
        typealias B = Metrics.Back
        let q = min(max(swipe.offset / max(1, width), 0), 1)
        progress = q
        switch swipe.kind {
        case .opener:
            cardScale = B.cardScale + (1 - B.cardScale) * q
            cardRadius = B.cardRadius * (1 - q)
            cardDim = B.cardDim * Double(1 - q)
            pageRadius = B.pageRadius * min(1, q / B.pageRadiusBy)
            shadow = 1 - q * B.shadowFade
        case .nothing:
            cardScale = 1
            cardRadius = 0
            cardDim = 0
            pageRadius = 0
            shadow = swipe.offset > 0 ? 1 : 0
        }
    }
}

/// The opener's page under the card: alive when it is, else its picture.
private struct OpenerCard: UIViewRepresentable {
    let tab: Tab
    let pool: WebPool

    func makeUIView(context: Context) -> NeighborSlot { NeighborSlot() }

    func updateUIView(_ slot: NeighborSlot, context: Context) { slot.show(tab, pool: pool) }

    static func dismantleUIView(_ slot: NeighborSlot, coordinator: ()) { slot.letGo() }
}

/// Puts the left edge's recognizer on the window the app draws in.
private struct BackGestureHost: UIViewRepresentable {
    let gestures: BackGestures

    func makeUIView(context: Context) -> Host { Host() }

    func updateUIView(_ host: Host, context: Context) { host.gestures = gestures }

    final class Host: UIView {
        private weak var installed: UIWindow?
        var gestures: BackGestures? {
            didSet { if oldValue !== gestures { attach() } }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            attach()
        }

        private func attach() {
            if let installed, installed !== window { gestures?.uninstall(from: installed) }
            installed = window
            if let window { gestures?.install(on: window) }
        }
    }
}
