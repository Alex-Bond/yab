import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// The tray itself: its head, the body of the step it is on (the old one
/// fading under the new one as they swap), and the button at its foot. Its
/// rect is the stage's, worked out from the springs; inside, nothing moves on
/// its own.
struct ApprovalTrayView: View {
    @Environment(AppModel.self) private var app
    let tray: ApprovalTray
    let content: ApprovalContent
    let geometry: ApprovalGeometry
    private typealias M = ApprovalMetrics

    var body: some View {
        let rect = geometry.trayRect
        let fold = geometry.foldShare
        let shape = RoundedRectangle(cornerRadius: M.radius, style: .continuous)
        VStack(spacing: 0) {
            ApprovalHead(tray: tray, content: content)
                .frame(height: M.header)
            ApprovalBodies(tray: tray, content: content, cap: geometry.bodyCap)
                .opacity(geometry.bodyShown)
            ApprovalFooter(tray: tray, content: content)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { tray.measuredFooter($0) }
                .opacity(tray.step == .cards || tray.step == .places ? 0 : geometry.bodyShown)
                .allowsHitTesting(!(tray.step == .cards || tray.step == .places))
        }
        .frame(width: geometry.width, height: geometry.trayHeight, alignment: .top)
        .coordinateSpace(name: ApprovalGeometry.traySpace)
        // The surface is the rect: as it shrinks its top comes down, the head
        // riding it and the rest fading, cut off by the bottom edge.
        .frame(width: rect.width, height: rect.height, alignment: .top)
        .background(Ink.card)
        .clipShape(shape)
        // Behind a window it steps back and darkens, about its bottom.
        .overlay(shape.fill(Color.black.opacity(0.25 * Double(min(1, max(0, tray.win))))).allowsHitTesting(false))
        .scaleEffect(geometry.behindScale, anchor: .bottom)
        .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        .position(x: rect.midX, y: rect.midY)
        .opacity(tray.trayFade)
        .gesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .named(ApprovalGeometry.screenSpace))
                .onChanged { tray.trayDragChanged($0.translation.height) }
                .onEnded { tray.trayDragEnded($0.translation.height, velocity: $0.velocity.height, height: geometry.trayHeight) }
        )
        .allowsHitTesting(tray.windowItem == nil && tray.pictureFile == nil && fold < 0.1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("approval.tray")
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - the head

/// Who or what it is about, with the agent's face on the corner of its mark,
/// and × to say no; deeper in, ‹ and the step's name.
struct ApprovalHead: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    private typealias M = ApprovalMetrics

    var body: some View {
        let deep = tray.step != .root
        let s = min(1, max(0, tray.swap))
        ZStack {
            // The step's head and the root's cross over each other in place.
            root.opacity(Double(deep ? 1 - s : (tray.leaving == nil ? 1 : s)))
                .allowsHitTesting(!deep)
            if deep || tray.leaving.map({ $0 != .root }) == true {
                stepHead(deep ? tray.step : (tray.leaving ?? .root))
                    .opacity(Double(deep ? s : 1 - s))
                    .allowsHitTesting(deep)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }

    private var root: some View {
        HStack(spacing: 12) {
            ApprovalMark(mark: content.mark, size: M.mark, face: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(content.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if !content.sub.isEmpty || tray.receiptWords != nil {
                    // Where it comes from gives way to what came of it.
                    ZStack(alignment: .leading) {
                        Text(content.sub)
                            .opacity(1 - tray.receiptShown)
                        if let words = tray.receiptWords {
                            Text(words)
                                .opacity(tray.receiptShown)
                                .accessibilityIdentifier("approval.receipt")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if tray.queued > 0 {
                Text("1 of \(tray.queued + 1)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ChatInk.gray(0.6))
                    .monospacedDigit()
                    .opacity(1 - tray.receiptShown)
            }
            ZStack {
                round("xmark", label: content.chat ? "Not Now" : "Don’t Allow", id: "approval.no") { tray.no() }
                    .opacity(tray.canChange ? 1 : 0)
                    .allowsHitTesting(tray.canChange)
                if tray.receiptDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: M.close, height: M.close)
                        .background(ApprovalInk.paid, in: Circle())
                        .opacity(tray.receiptShown)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func stepHead(_ step: ApprovalTray.Step) -> some View {
        let words: (String, String) = switch step {
        case .cards: ("Pay With", "Cards in Yab")
        case .places: ("Ship To", "Addresses in Yab")
        case .newCard: ("Add Card", "Kept in Yab on your Mac")
        case .newPlace: ("Add Address", "Kept in Yab on your Mac")
        case .all: ("\(content.items.count) mails", content.sub)
        case .root: ("", "")
        }
        return HStack(spacing: 12) {
            round("chevron.left", label: "Back", id: "approval.back") { tray.back() }
            VStack(alignment: .leading, spacing: 1) {
                Text(words.0).font(.system(size: 15, weight: .semibold)).foregroundStyle(Ink.primary)
                Text(words.1).font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6)).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    private func round(_ symbol: String, label: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: M.close, height: M.close)
                .background(ChatInk.fill(0.12), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// The thing's own mark: the site's icon, a person's initials, Messages',
/// files', Mail's; the agent's face on its corner when an agent asks.
struct ApprovalMark: View {
    let mark: ApprovalContent.Mark
    var size: CGFloat = ApprovalMetrics.mark
    var face = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                switch mark {
                case .site(let host):
                    Favicon(icon: host.isEmpty ? "face" : host, host: host.isEmpty ? nil : host, size: size)
                case .person(let name):
                    Text(ApprovalContent.initials(name))
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(ApprovalContent.tint(name), in: Circle())
                case .messages:
                    Image(systemName: "message.fill")
                        .font(.system(size: size * 0.48))
                        .foregroundStyle(.white)
                        .frame(width: size, height: size)
                        .background(Color(red: 0.2, green: 0.78, blue: 0.35), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                case .files:
                    Image(systemName: "doc.fill")
                        .font(.system(size: size * 0.46))
                        .foregroundStyle(Ink.primary)
                        .frame(width: size, height: size)
                        .background(ChatInk.fill(0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                case .mail:
                    Glyph(.email1, size: size * 0.62, color: .white)
                        .frame(width: size, height: size)
                        .background(Color(red: 0.77, green: 0.13, blue: 0.12), in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                }
            }
            if face {
                ApprovalFaceBadge()
                    .offset(x: 4, y: 4)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The agent on a mark's corner, as on the Mac's cards (AskFaceBadge): a disc
/// that is the face itself, two upright eyes, cut out of the mark by a ring
/// of the card.
struct ApprovalFaceBadge: View {
    var body: some View {
        Canvas { context, canvas in
            let k = canvas.width / 16
            var eyes = Path()
            eyes.move(to: CGPoint(x: 6 * k, y: 6.4 * k)); eyes.addLine(to: CGPoint(x: 6 * k, y: 9 * k))
            eyes.move(to: CGPoint(x: 10 * k, y: 6.4 * k)); eyes.addLine(to: CGPoint(x: 10 * k, y: 9 * k))
            context.stroke(eyes, with: .color(Ink.card), style: StrokeStyle(lineWidth: 1.9 * k, lineCap: .round))
        }
        .frame(width: ApprovalMetrics.face, height: ApprovalMetrics.face)
        .background(Ink.primary, in: Circle())
        .background(Circle().fill(Ink.card).padding(-2))
    }
}
