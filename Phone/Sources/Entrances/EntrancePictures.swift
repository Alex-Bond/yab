import SwiftUI
import UIKit
import WidgetKit

/// Pictures of the ways into Yab as the system shows them (share.1-3,
/// widgets.1-3): the share sheet's card over the app it was shared from,
/// the Search and Ask widgets on the Home Screen and the Lock Screen. On an
/// iPhone the system draws them from the extensions; these named states draw
/// the same views (ShareCard, SearchWidgetFace) over a stand-in of the
/// system's ground, as OutsideYab does for the Live Activity.
enum EntrancePicture: Equatable {
    case share(SharedItems.Found?, ShareCardPhase)
    case homeScreen
    case lockScreen(SearchWidgetKind)
    /// The Now widget's faces (widgets.4-5): `few` the medium as it fills,
    /// else three rows, the small and the Lock Screen's.
    case now(few: Bool)
}

@MainActor
enum EntrancePictures {
    private static var window: UIWindow?

    static func show(_ picture: EntrancePicture) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let view: AnyView
        switch picture {
        case let .share(found, phase): view = AnyView(SharePicture(found: found, phase: phase))
        case .homeScreen: view = AnyView(HomeScreenPicture())
        case let .lockScreen(kind): view = AnyView(LockScreenWidgetsPicture(kind: kind))
        case let .now(few): view = AnyView(NowWidgetsPicture(few: few))
        }
        let host = PictureHost(rootView: view)
        host.view.backgroundColor = .clear
        let window = window ?? UIWindow(windowScene: scene)
        // Over the app, under the status bar, which the system's screens show too.
        window.windowLevel = .normal + 1
        window.backgroundColor = .clear
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.setNeedsStatusBarAppearanceUpdate()
        self.window = window
    }

    /// The light status bar the Home Screen and the Lock Screen wear; the
    /// share sheet's follows the app under it.
    private final class PictureHost: UIHostingController<AnyView> {
        override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    }
}

/// The share sheet's card from below, over the app it was shared from,
/// dimmed as a sheet dims it: as tall as the card and the home indicator.
private struct SharePicture: View {
    let found: SharedItems.Found?
    let phase: ShareCardPhase

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black.opacity(0.28)
                ShareCard(found: found, phase: phase)
                    .frame(height: ShareCardMetrics.sheetHeight + geo.safeAreaInsets.bottom)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: -6)
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.share")
    }
}

/// A stand-in for the system's wallpaper: the prototype's blues.
private struct PictureWallpaper: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0x8F / 255, green: 0x7B / 255, blue: 0xF0 / 255),
                                Color(red: 0x5B / 255, green: 0x6F / 255, blue: 0xD8 / 255),
                                Color(red: 0x2B / 255, green: 0x3A / 255, blue: 0x7A / 255),
                                Color(red: 0x12 / 255, green: 0x18 / 255, blue: 0x36 / 255)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// The Home Screen with Search and Ask side by side, small, their name under
/// each as the system writes it, and the dock.
private struct HomeScreenPicture: View {
    private typealias M = SearchWidgetMetrics

    var body: some View {
        GeometryReader { geo in
            let gap = (geo.size.width - M.small.width * 2) / 3
            ZStack(alignment: .top) {
                PictureWallpaper()
                HStack(spacing: gap) {
                    ForEach(SearchWidgetKind.allCases, id: \.self) { kind in
                        VStack(spacing: 6) {
                            SearchWidgetFace(kind: kind, family: .systemSmall, inWidget: false)
                                .padding(M.margin)
                                .frame(width: M.small.width, height: M.small.height)
                                .background(EntranceLook.surface, in: RoundedRectangle(cornerRadius: M.smallRadius, style: .continuous))
                            Text("Yab")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(.top, geo.safeAreaInsets.top + 14)
                VStack {
                    Spacer()
                    HStack(spacing: 26) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(.white.opacity(0.22))
                                .frame(width: 62, height: 62)
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 34, style: .continuous))
                    .padding(.horizontal, 12)
                    .padding(.bottom, max(geo.safeAreaInsets.bottom - 14, 8))
                }
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.home")
    }
}

/// The Lock Screen under its clock: the rectangular widget of `kind` and both
/// round ones, as one row of the Lock Screen's widgets.
private struct LockScreenWidgetsPicture: View {
    let kind: SearchWidgetKind

    private typealias M = SearchWidgetMetrics

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                PictureWallpaper()
                VStack(spacing: 0) {
                    Text("Friday, October 9")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(height: 22)
                    Text("9:41")
                        .font(.system(size: 96, weight: .semibold))
                        .tracking(-0.04 * 96)
                        .foregroundStyle(.white)
                        .frame(height: 104)
                    HStack(spacing: 12) {
                        SearchWidgetFace(kind: kind, family: .accessoryRectangular, inWidget: false)
                            .frame(width: M.rectangular.width, height: M.rectangular.height)
                        ForEach(SearchWidgetKind.allCases, id: \.self) { round in
                            SearchWidgetFace(kind: round, family: .accessoryCircular, inWidget: false)
                                .frame(width: M.circular.width, height: M.circular.height)
                        }
                    }
                    .padding(.top, 12)
                }
                .padding(.top, geo.safeAreaInsets.top + 22)
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.lock.widgets")
    }
}

/// The Now widget's faces over the wallpaper, as WidgetKit would lay them
/// out on a 402-point iPhone: `few`, the medium with nothing, one row and
/// two; else three rows, the small with a row and with nothing, and the
/// Lock Screen's.
private struct NowWidgetsPicture: View {
    let few: Bool

    private typealias M = SearchWidgetMetrics
    private let rows = EntranceSamples.nowRows

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                PictureWallpaper()
                VStack(spacing: 18) {
                    if few {
                        medium([])
                        medium(Array(rows.prefix(1)))
                        medium(Array(rows.prefix(2)))
                    } else {
                        medium(rows)
                        HStack(spacing: 24) {
                            small(rows)
                            small([])
                        }
                        NowWidgetFace(rows: rows, family: .accessoryRectangular)
                            .padding(.horizontal, 10)
                            .frame(width: M.rectangular.width + 20, height: M.rectangular.height)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(.top, geo.safeAreaInsets.top + 14)
            }
            .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.now")
    }

    private func medium(_ rows: [NowShelfRow]) -> some View {
        NowWidgetFace(rows: rows, family: .systemMedium)
            .padding(M.margin)
            .frame(width: NowWidgetMetrics.medium.width, height: NowWidgetMetrics.medium.height)
            .background(EntranceLook.surface, in: RoundedRectangle(cornerRadius: M.smallRadius, style: .continuous))
    }

    private func small(_ rows: [NowShelfRow]) -> some View {
        NowWidgetFace(rows: rows, family: .systemSmall)
            .padding(M.margin)
            .frame(width: M.small.width, height: M.small.height)
            .background(EntranceLook.surface, in: RoundedRectangle(cornerRadius: M.smallRadius, style: .continuous))
    }
}
