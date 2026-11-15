import SwiftUI
import UIKit

/// Pictures of Yab outside Yab (out.1...out.8): another app in front with
/// the task in the Dynamic Island, and the Lock Screen with its Live
/// Activity. On an iPhone the system draws both from the widget; these
/// named states draw the same views (TaskActivityViews) over a stand-in of
/// the system's ground, so the frames can be laid beside the prototype's.
/// The real activity is proved on the simulator by TasksTests.
enum OutsideScene: Equatable {
    /// Another app (a Telegram chat) in front; the Island compact.
    case island(TaskActivityAttributes.ContentState)
    /// The Lock Screen: the card; `open` once Face ID knows the face.
    case lock(TaskActivityAttributes.ContentState, open: Bool)

    var isIsland: Bool {
        if case .island = self { return true }
        return false
    }
}

/// Another app in front and the Island over it (out.1, out.2), with the
/// status bar the system shows beside a compact activity: the clock, Wi-Fi
/// and the battery, the signal bars gone to make room. An iPhone without an
/// Island (16e) shows the activity on the Lock Screen only: the app in
/// front keeps its whole status bar.
struct OutsideYabPicture: View {
    let scene: OutsideScene
    let top: DeviceTop

    var body: some View {
        GeometryReader { geo in
            let bar = StatusBarLayout(width: geo.size.width, top: top, beside: scene.isIsland)
            ZStack(alignment: .top) {
                TelegramPicture(width: geo.size.width)
                StatusBarPicture(layout: bar)
                if case let .island(state) = scene, top == .island {
                    IslandPicture(state: state)
                        .padding(.top, IslandPicture.top)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.island")
    }
}

/// What the top of this iPhone has: the Dynamic Island, or a notch.
enum DeviceTop: Equatable {
    case island, notch

    /// From the window's safe area: 59 or 62 over an Island, 47 under a notch.
    @MainActor
    static var current: DeviceTop {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let top = scene?.windows.first?.safeAreaInsets.top ?? 62
        return top >= OutsideLook.islandSafeTop ? .island : .notch
    }
}

/// Where the system puts the status bar's items, by the width of the screen
/// and its top, measured on the simulators (TasksTests'
/// testTheStatusBarBesideACompactActivity): beside an Island the clock is 7
/// inside the middle of the left ear, Wi-Fi and the battery right of the
/// middle of the right one; under a notch the signal bars stay too.
struct StatusBarLayout: Equatable {
    var time: CGPoint
    var signal: CGPoint?
    var wifi: CGPoint
    var battery: CGPoint

    init(width: CGFloat, top: DeviceTop, beside activity: Bool) {
        typealias L = OutsideLook
        switch top {
        case .island:
            let ear = (width - Metrics.Island.size.width) / 2
            let left = ear / 2
            let right = width - ear / 2
            time = CGPoint(x: left + L.timeFromEar, y: L.barMid)
            // Beside a compact activity the signal bars make room for it.
            signal = activity ? nil : CGPoint(x: right + L.signalFromEar, y: L.barMid)
            wifi = CGPoint(x: right + L.wifiFromEar, y: L.barMid)
            battery = CGPoint(x: right + L.batteryFromEar, y: L.barMid)
        case .notch:
            time = CGPoint(x: L.notchTime, y: L.notchMid)
            signal = CGPoint(x: width - L.notchSignalFromEdge, y: L.notchMid)
            wifi = CGPoint(x: width - L.notchWifiFromEdge, y: L.notchMid)
            battery = CGPoint(x: width - L.notchBatteryFromEdge, y: L.notchMid)
        }
    }
}

/// The status bar of another app in front, as the system draws it.
private struct StatusBarPicture: View {
    let layout: StatusBarLayout

    private typealias L = OutsideLook

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("9:41")
                .font(.system(size: L.timeFont, weight: .semibold))
                .frame(width: L.timeWidth, height: L.timeHeight)
                .position(layout.time)
            if let signal = layout.signal {
                Image(systemName: "cellularbars")
                    .font(.system(size: L.glyphFont, weight: .semibold))
                    .position(signal)
            }
            Image(systemName: "wifi")
                .font(.system(size: L.glyphFont, weight: .semibold))
                .position(layout.wifi)
            Image(systemName: "battery.100percent")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: L.battery)
                .position(layout.battery)
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// The system's own sizes in the pictures of outside Yab.
enum OutsideLook {
    /// Over an Island the safe area's top is 59 or 62; under a notch, 47.
    static let islandSafeTop: CGFloat = 55
    static let timeFont: CGFloat = 17
    static let timeWidth: CGFloat = 124
    static let timeHeight: CGFloat = 22
    static let glyphFont: CGFloat = 15
    static let battery: CGFloat = 25
    /// Beside an Island: the items' middles from the middle of their ear
    /// (402 wide: the clock at 62, Wi-Fi at 329.7, the battery at 357.5).
    static let barMid: CGFloat = 32.3
    static let timeFromEar: CGFloat = -7
    static let signalFromEar: CGFloat = -26
    static let wifiFromEar: CGFloat = -3.3
    static let batteryFromEar: CGFloat = 24.5
    /// Under a notch (16e).
    static let notchMid: CGFloat = 24
    static let notchTime: CGFloat = 54
    static let notchSignalFromEdge: CGFloat = 86
    static let notchWifiFromEdge: CGFloat = 62
    static let notchBatteryFromEdge: CGFloat = 33
}

/// The compact Island as the system draws a Live Activity's, measured on
/// the simulator's real one (TasksTests): the camera stays where it is
/// (126 wide, centered), the site's icon grows the Island to its left and
/// the words to its right, each side as wide as what it holds, 7 and 8 in
/// from the ends. For "Code" that is x 107 to 305 at y 14, 36 high; the
/// prototype draws 200 at x 101 for every word and puts a long one
/// ("4 direct") under the camera.
struct IslandPicture: View {
    let state: TaskActivityAttributes.ContentState

    var body: some View {
        IslandAroundCamera(camera: Metrics.Island.size.width) {
            Capsule(style: .continuous).fill(Color.black)
            TaskIslandLeading(state: state)
                .padding(.leading, Self.leading)
            TaskIslandTrailing(state: state)
                .padding(.trailing, Self.trailing)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("outside.island.compact")
    }

    static let leading: CGFloat = 7
    static let trailing: CGFloat = 8
    /// Where the system draws a compact activity: 14 down, 36 high.
    static let top: CGFloat = 14
    static let height: CGFloat = 36
}

/// The Island's black around a camera that stays put: the first view is the
/// Island's shape, the second stands left of the camera, the third right of it.
private struct IslandAroundCamera: Layout {
    let camera: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? Metrics.screen.width, height: proposal.height ?? IslandPicture.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let left = subviews[1].sizeThatFits(.unspecified).width
        let right = subviews[2].sizeThatFits(.unspecified).width
        let cameraLeft = bounds.midX - camera / 2
        let shape = CGRect(x: cameraLeft - left, y: bounds.minY, width: left + camera + right, height: bounds.height)
        subviews[0].place(at: shape.origin, anchor: .topLeading, proposal: ProposedViewSize(shape.size))
        subviews[1].place(at: CGPoint(x: cameraLeft, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: cameraLeft + camera, y: bounds.midY), anchor: .leading, proposal: .unspecified)
    }
}

/// The Lock Screen (out.3...out.8): the wallpaper, the lock, the date and
/// time, the card, the two round buttons; "Swipe up to open" once Face ID
/// knows the face.
struct LockScreenPicture: View {
    let state: TaskActivityAttributes.ContentState
    let open: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .top) {
                Wallpaper()
                Glyph(.lock2, size: 18, color: .white)
                    .opacity(open ? 0 : 1)
                    .offset(y: open ? -6 : 0)
                    .padding(.top, 56)
                Text("Monday, October 5")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.01 * 19)
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(height: 19)
                    .padding(.top, 84)
                Text("18:49")
                    .font(.system(size: 96, weight: .semibold))
                    .tracking(-0.04 * 96)
                    .foregroundStyle(.white)
                    .frame(height: 96)
                    .padding(.top, 102)
                VStack {
                    Spacer()
                    TaskLockCard(state: state, locked: !open) { button in
                        ActivityButtonLabel(button: button)
                    }
                    .frame(width: size.width - Metrics.Edge.bar * 2, alignment: .leading)
                    .background(ActivityLook.card, in: RoundedRectangle(cornerRadius: Metrics.LiveActivity.radius, style: .continuous))
                    .overlay(alignment: .top) {
                        RoundedRectangle(cornerRadius: Metrics.LiveActivity.radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center), lineWidth: 1)
                    }
                    .padding(.bottom, Metrics.LiveActivity.bottom)
                    .accessibilityIdentifier("outside.lock.card")
                }
                VStack {
                    Spacer()
                    HStack {
                        Circle().fill(.white.opacity(0.16)).frame(width: 50, height: 50)
                        Spacer()
                        Glyph(.window, size: 22, color: .white)
                            .frame(width: 50, height: 50)
                            .background(.white.opacity(0.16), in: Circle())
                    }
                    .padding(.horizontal, 48)
                    .padding(.bottom, 46)
                }
                if open {
                    VStack {
                        Spacer()
                        Text("Swipe up to open")
                            .font(.system(size: 14, weight: .medium))
                            .tracking(-0.01 * 14)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(height: 14)
                            .padding(.bottom, 30)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
        .ignoresSafeArea()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("outside.lock")
    }
}

/// The prototype's wallpaper: radial-gradient(110% 70% at 20% 10%, #8F7BF0,
/// #5B6FD8 35%, #2B3A7A 70%, #121836).
private struct Wallpaper: View {
    var body: some View {
        Canvas { context, size in
            let gradient = Gradient(stops: [
                .init(color: Color(red: 0x8F / 255, green: 0x7B / 255, blue: 0xF0 / 255), location: 0),
                .init(color: Color(red: 0x5B / 255, green: 0x6F / 255, blue: 0xD8 / 255), location: 0.35),
                .init(color: Color(red: 0x2B / 255, green: 0x3A / 255, blue: 0x7A / 255), location: 0.7),
                .init(color: Color(red: 0x12 / 255, green: 0x18 / 255, blue: 0x36 / 255), location: 1),
            ])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0x12 / 255, green: 0x18 / 255, blue: 0x36 / 255)))
            let rx = size.width * 1.1, ry = size.height * 0.7
            var stretched = context
            stretched.translateBy(x: size.width * 0.2, y: size.height * 0.1)
            stretched.scaleBy(x: rx / ry, y: 1)
            let reach = ry * 1.6
            stretched.fill(Path(CGRect(x: -reach, y: -reach, width: reach * 2, height: reach * 2)),
                           with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: ry))
        }
    }
}

/// Another app: Mira's chat with Jonas in Telegram, as the prototype draws it.
private struct TelegramPicture: View {
    /// The screen's width: a bubble is at most 82 % of it.
    let width: CGFloat
    private let blue = Color(red: 0x2A / 255, green: 0xAB / 255, blue: 0xEE / 255)
    private let gray = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)
    private let bar = Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255).opacity(0.94)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 2) {
                    Glyph(.chevronLeft, size: 22, color: blue)
                    Text("Chats").font(.system(size: 17)).tracking(-0.01 * 17).foregroundStyle(blue)
                }
                VStack(spacing: 3) {
                    Text("Jonas Berg").font(.system(size: 16, weight: .semibold)).tracking(-0.01 * 16).foregroundStyle(.black)
                    Text("last seen recently").font(.system(size: 12.5)).tracking(-0.01 * 12.5).foregroundStyle(gray)
                }
                .frame(maxWidth: .infinity)
                Text("JB")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.01 * 14)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(LinearGradient(colors: [Color(red: 0x7B / 255, green: 0xC8 / 255, blue: 0x62 / 255),
                                                        Color(red: 0x3E / 255, green: 0x9F / 255, blue: 0x4D / 255)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            }
            .padding(EdgeInsets(top: 56, leading: 12, bottom: 8, trailing: 12))
            .background(bar)
            .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.12)).frame(height: 0.5) }
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                Text("Today")
                    .font(.system(size: 12.5, weight: .medium))
                    .tracking(-0.01 * 12.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 6)
                message("Are you coming Thursday? Requests close tonight", incoming: true, time: "20:41")
                bubble(incoming: true, link: true, time: "20:41") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(blue).frame(width: 4)
                            VStack(alignment: .leading, spacing: 0) {
                                Text("Lumen").font(.system(size: 14, weight: .semibold)).tracking(-0.01 * 14).foregroundStyle(blue)
                                Text("Design Systems Night · Stockholm").font(.system(size: 14, weight: .semibold))
                                    .tracking(-0.01 * 14)
                                Text("Thu, Oct 8 · 18:00 · Södermalm").font(.system(size: 13)).tracking(-0.01 * 13).foregroundStyle(Ink.rowGlyph).padding(.top, 2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        Text("lumen.events/e/design-systems-night")
                            .font(.system(size: 15)).tracking(-0.01 * 15).underline().foregroundStyle(blue)
                            .padding(.horizontal, 6)
                    }
                }
                message("Looking now", incoming: false, time: "21:13")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(EdgeInsets(top: 12, leading: 10, bottom: 20, trailing: 10))
            .frame(maxHeight: .infinity)
            Text("Message")
                .font(.system(size: 16))
                .tracking(-0.01 * 16)
                .foregroundStyle(Color(red: 0xc7 / 255, green: 0xc7 / 255, blue: 0xcc / 255))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 36)
                .background(.white, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                .padding(EdgeInsets(top: 8, leading: 10, bottom: 40, trailing: 10))
                .background(bar)
                .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.12)).frame(height: 0.5) }
        }
        .background(Color(red: 0xE7 / 255, green: 0xDF / 255, blue: 0xD4 / 255))
        .accessibilityHidden(true)
    }

    /// Words with the time at the end of their last line, Telegram's way: room
    /// for the time is kept in the words, the time laid over it.
    private func message(_ words: String, incoming: Bool, time: String) -> some View {
        (Text(words) + Text("\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}\u{2007}").font(.system(size: 11.5)))
            .font(.system(size: 16))
            .tracking(-0.01 * 16)
            .foregroundStyle(.black)
            .lineHeight(1.3, size: 16)
            .overlay(alignment: .bottomTrailing) {
                Text(time).font(.system(size: 11.5)).tracking(-0.01 * 11.5).foregroundStyle(gray)
                    .offset(y: 2)
            }
            .padding(EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
            .background(incoming ? Color.white : Color(red: 0xE1 / 255, green: 1, blue: 0xC7 / 255),
                        in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: incoming ? 6 : 18,
                                                   bottomTrailingRadius: incoming ? 18 : 6, topTrailingRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
            .frame(maxWidth: width * 0.82 - 10, alignment: incoming ? .leading : .trailing)
    }

    private func bubble<Content: View>(incoming: Bool, link: Bool = false, time: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            content()
                .foregroundStyle(.black)
            Text(time).font(.system(size: 11.5)).tracking(-0.01 * 11.5).foregroundStyle(gray)
                .frame(maxWidth: link ? .infinity : nil, alignment: link ? .leading : .trailing)
                .padding(.horizontal, link ? 6 : 0)
        }
        .padding(link ? EdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6) : EdgeInsets(top: 8, leading: 12, bottom: 6, trailing: 12))
        .background(incoming ? Color.white : Color(red: 0xE1 / 255, green: 1, blue: 0xC7 / 255),
                    in: UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: incoming ? 6 : 18,
                                               bottomTrailingRadius: incoming ? 18 : 6, topTrailingRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 1)
        .frame(maxWidth: width * 0.82 - 10, alignment: incoming ? .leading : .trailing)
    }
}

/// Pictures of the system's own screens stand over the status bar, as the
/// system's do: a window of their own above it, for the named states only.
@MainActor
enum OutsideWindow {
    private static var window: UIWindow?

    static func show(_ scene: OutsideScene?, app: AppModel) {
        guard let scene else {
            window?.isHidden = true
            window = nil
            return
        }
        guard let windowScene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        let picture: AnyView
        switch scene {
        case let .lock(state, open): picture = AnyView(LockScreenPicture(state: state, open: open))
        case .island: picture = AnyView(OutsideYabPicture(scene: scene, top: DeviceTop.current))
        }
        let host = PictureHost(rootView: picture)
        host.view.backgroundColor = .black
        let window = window ?? UIWindow(windowScene: windowScene)
        window.windowLevel = .statusBar + 1
        window.rootViewController = host
        // Key, so its controller says the status bar goes: the Lock Screen has its own clock.
        window.makeKeyAndVisible()
        host.setNeedsStatusBarAppearanceUpdate()
        self.window = window
    }

    private final class PictureHost: UIHostingController<AnyView> {
        override var prefersStatusBarHidden: Bool { true }
    }
}
