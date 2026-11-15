import LocalAuthentication
import SwiftUI
#if canImport(SyncKit)
import SyncKit
#endif

/// The tray's foot: one button with the action's own verb and the mark of
/// how this iPhone proves it's you, and a quiet line under it for what is
/// going on (paying on the site, the order, what went wrong). The window's
/// foot is this same view, standing where this one stands.
struct ApprovalFooter: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    private typealias M = ApprovalMetrics

    var body: some View {
        VStack(spacing: 6) {
            switch tray.step {
            case .newCard:
                save("Save Card", ready: tray.cardForm.filled != nil, id: "approval.saveCard") { tray.saveCard() }
            case .newPlace:
                save("Save Address", ready: tray.placeForm.filled != nil, id: "approval.savePlace") { tray.savePlace() }
            default:
                if content.kind == .accounts {
                    Text(tray.phase == .ready ? "Tap an account to sign in" : "")
                        .font(.system(size: 13)).foregroundStyle(ChatInk.gray(0.6))
                        .frame(height: 20)
                } else {
                    ApprovalYesButton(tray: tray, content: content)
                }
            }
            if content.kind == .pay || !tray.footLine.isEmpty {
                Text(tray.footLine.isEmpty ? " " : tray.footLine)
                    .font(.system(size: 13))
                    .foregroundStyle(tray.phase == .failed || tray.phase == .declined ? Color(red: 1, green: 0.23, blue: 0.19) : ChatInk.gray(0.6))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 18)
                    .accessibilityIdentifier("approval.footLine")
            }
        }
        .padding(.horizontal, M.pad)
        .padding(.top, 12)
        .padding(.bottom, M.pad)
    }

    private func save(_ title: String, ready: Bool, id: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ApprovalInk.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: M.button)
                .background(ApprovalInk.ink, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(ready ? 1 : 0.35)
        .disabled(!ready)
        .accessibilityIdentifier(id)
    }
}

/// The yes: the verb and the proof's mark; then the check as it happens,
/// the site being paid with its arc, paid in green, or what to do next.
struct ApprovalYesButton: View {
    let tray: ApprovalTray
    let content: ApprovalContent
    private typealias M = ApprovalMetrics

    var body: some View {
        let phase = tray.phase
        let reAsked = phase == .declined && tray.reAsked
        let label: String = switch phase {
        case .declined: reAsked ? "Try Again \u{00B7} \(content.pay?.amount ?? "")" : "Close"
        case .failed: "Close"
        default: content.verb
        }
        Button {
            if phase == .failed || (phase == .declined && !reAsked) { tray.dismiss() } else { tray.yes() }
        } label: {
            ZStack {
                HStack(spacing: 8) {
                    if phase == .ready || reAsked { ApprovalProofGlyph(size: 20) }
                    Text(label).font(.system(size: 17, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .opacity(phase == .ready || phase == .proving || phase == .declined || phase == .failed ? 1 : 0)
                ApprovalWorking(phase: phase, site: content.name)
            }
            .foregroundStyle(phase == .paid || phase == .done ? Color.white : ApprovalInk.onInk)
            .frame(maxWidth: .infinity)
            .frame(height: M.button)
            .background(phase == .paid || phase == .done ? ApprovalInk.paid : ApprovalInk.ink, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(ApprovalButtonPress())
        .disabled(!(phase == .ready || phase == .declined || phase == .failed))
        .accessibilityLabel(label)
        .accessibilityIdentifier("approval.yes")
    }
}

/// What the button shows while it isn't a button: the ring drawing round
/// as the answer goes, the arc while the site is paid, the tick once paid.
struct ApprovalWorking: View {
    let phase: ApprovalTray.Phase
    let site: String
    @State private var drawn: CGFloat = 0

    var body: some View {
        ZStack {
            switch phase {
            case .sending:
                Circle().trim(from: 0, to: drawn)
                    .stroke(style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 24, height: 24)
                    .onAppear {
                        drawn = 0
                        Motion.approvalRing.run { drawn = 1 }
                    }
            case .paying:
                HStack(spacing: 8) {
                    TimelineView(.animation) { context in
                        let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                        Circle().trim(from: 0, to: 0.28)
                            .stroke(style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                            .rotationEffect(.degrees(turn * 360))
                            .frame(width: 18, height: 18)
                    }
                    Text("Paying on \(site)").font(.system(size: 16, weight: .semibold)).lineLimit(1)
                }
            case .paid, .done:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 16, weight: .bold))
                    Text(phase == .paid ? "Paid" : "Done").font(.system(size: 17, weight: .semibold))
                }
                .transition(.opacity)
            default:
                EmptyView()
            }
        }
    }
}

struct ApprovalButtonPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// How this iPhone proves it's you, as the button's mark: Face ID's, Touch
/// ID's (iPhone SE), Optic ID's, or a lock where only the passcode is set.
struct ApprovalProofGlyph: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: ApprovalProof.current.symbol)
            .font(.system(size: size * 0.9, weight: .medium))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum ApprovalProof: String {
    case faceID, touchID, opticID, passcode

    var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock"
        }
    }

    /// Asked of LAContext once; a named state or a test may say which with
    /// -YabProof faceID|touchID|passcode.
    @MainActor static let current: ApprovalProof = {
        let arguments = ProcessInfo.processInfo.arguments
        if let i = arguments.firstIndex(of: "-YabProof"), i + 1 < arguments.count, let said = ApprovalProof(rawValue: arguments[i + 1]) {
            return said
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .passcode }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }()
}

/// The tray's own inks: the confirm button filled with ink, as Yab's trays'.
enum ApprovalInk {
    static let ink = AppearanceColors.color(0x161615, 0xF2F2F7)
    static let onInk = AppearanceColors.color(0xFFFFFF, 0x000000)
    static let paid = Color(red: 0.2, green: 0.78, blue: 0.35)
    static let declined = Color(red: 1, green: 0.23, blue: 0.19)
}
