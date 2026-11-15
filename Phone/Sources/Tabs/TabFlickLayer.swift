import SwiftUI

/// The flick's page (prototype scene 6): let go of the lifted card and the
/// previous tab's page grows out of it to the whole screen, straightening
/// from the card's turn and showing more of its top as it comes, over the
/// page in front, which darkens a little under it, and under the chrome.
/// Its live page takes over from the picture when it has grown
/// (TabStack.landFlick).
struct TabFlickLayer: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            let stack = TabStack.of(app)
            ZStack(alignment: .topLeading) {
                if let flick = stack.flick, flick.released {
                    let g = min(max(stack.growth, 0), 1)
                    let full = CGRect(origin: .zero, size: geo.size)
                    let rect = TabGalleryMotion.mix(flick.start, full, g)
                    let grown = flick.start.width / Metrics.TabStack.cardWidth
                    let lifted = Metrics.TabStack.cardRadius * grown
                    // The card's rim, as the lifted card wore it, gone as the page grows.
                    let rim = Metrics.TabStack.rim * grown * (1 - g)
                    let corners = RoundedRectangle(cornerRadius: lerp(lifted, 0, g), style: .continuous)
                    let top = geo.size.height > 0 ? Metrics.statusBar / geo.size.height : 0
                    Color.black.opacity(Metrics.TabStack.flickDim * Double(g))
                    TabPicture(tab: flick.target, image: stack.picture(flick.target), cropTop: lerp(top, 0, g),
                               iconSize: lerp(Metrics.TabStack.fallbackIcon, 32, g), screen: geo.size)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(corners)
                        .overlay {
                            corners.strokeBorder(Color.white.opacity(Double(Metrics.TabStack.rimAlpha)), lineWidth: rim)
                        }
                        .shadow(color: .black.opacity(Metrics.TabStack.flickShadowAlpha * Double(1 - g)),
                                radius: Metrics.TabStack.flickShadow / 2, y: Metrics.TabStack.flickShadow / 3)
                        .rotationEffect(.degrees(Double(lerp(Metrics.TabStack.frontTurn, 0, g))))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .onAppear { stack.screen = geo.size }
            .onChange(of: geo.size) { stack.screen = geo.size }
        }
        .ignoresSafeArea()
        // The page under it takes no touch while the other one grows over it.
        .allowsHitTesting(TabStack.of(app).flick?.released == true)
        .accessibilityHidden(true)
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
}
