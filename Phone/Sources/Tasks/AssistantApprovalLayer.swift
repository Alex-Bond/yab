import SwiftUI
import UIKit
#if canImport(SyncKit)
import SyncKit
#endif

/// A question from an agent on a Mac in this account's Sync, as a tray
/// under the thumb (docs/approvals.md, "On the iPhone"; the picked prototype
/// claude.ai/artifact/MZjAeESmzDF1vxDr36b3cx). It shows what is being
/// approved, not a box of lines: the receipt, the mail as it will go, the
/// file's pages, the accounts. Listed things open where they lie into a
/// window to be read, a file's page out of its thumbnail; a payment's card
/// and address change as on the Mac's pay sheet. The yes is a button with
/// the action's own verb, proven with Face ID, Touch ID or the passcode
/// first; × or the tray pulled down is the no. Then the tray shrinks into its
/// head and says what came of it. The agent and its relay can't press it.
struct AssistantApprovalLayer: View {
    @Environment(AppModel.self) private var app
    @State private var tray = ApprovalTray.shared

    var body: some View {
        let sync = app.sync
        let hidden = app.hasPrivateForeground
        GeometryReader { geo in
            let insets = ApprovalScreen.insets
            ApprovalStage(tray: tray, screen: geo.size, safeTop: insets.top)
                .onChange(of: geo.size, initial: true) { _, size in
                    ApprovalTrace.shared?.screen = size
                    ApprovalTrace.shared?.safeTop = insets.top
                }
                .opacity(hidden ? 0 : 1)
                .allowsHitTesting(!hidden && tray.isUp)
                .accessibilityHidden(hidden || !tray.isUp)
        }
        .ignoresSafeArea()
        .onAppear {
            tray.app = app
            tray.onFree = { present() }
            present()
        }
        .onChange(of: sync.assistantApprovalsTick) { present() }
        .onChange(of: sync.presentedAssistantApproval?.id) { present() }
        .onChange(of: sync.assistantApprovalReceipt) { present() }
        .onChange(of: sync.assistantApprovalResults) { present() }
        .onChange(of: KeyboardWatch.shared.height) { _, height in tray.keyboard(height) }
        .onChange(of: tray.isUp) { _, up in if up { ApprovalTrace.shared?.start() } }
    }

    private func present() {
        ApprovalTrace.mark("present")
        let sync = app.sync
        if let receipt = sync.assistantApprovalReceipt, tray.request == nil, tray.receiptWords == nil {
            // An old notification of a question answered on the Mac.
            sync.assistantApprovalReceipt = nil
            tray.sayReceipt(receipt)
            return
        }
        // The question in front, unless the tray is still busy with one
        // answered here: then the one it follows, for its result.
        let next = sync.presentedAssistantApproval
        tray.show(next, detail: next.flatMap { sync.assistantDetail($0) })
        tray.queued = max(0, sync.assistantApprovals.count - (tray.request.map { r in sync.assistantApprovals.contains { $0.id == r.id } ? 1 : 0 } ?? 1))
        if let request = tray.request { tray.result(sync.assistantApprovalResults[request.id]) }
    }
}

/// The window's insets, read from the scene: the layer ignores the safe area.
@MainActor
enum ApprovalScreen {
    static var insets: UIEdgeInsets {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return scene?.keyWindow?.safeAreaInsets ?? scene?.windows.first?.safeAreaInsets ?? UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    }
}

// MARK: - the stage

/// The dim, the tray, the window, the page full screen and a lone receipt, in
/// screen points, every rect worked out from the tray's springs each frame.
struct ApprovalStage: View {
    let tray: ApprovalTray
    let screen: CGSize
    let safeTop: CGFloat

    var body: some View {
        let geometry = ApprovalGeometry(tray: tray, screen: screen, safeTop: safeTop)
        ZStack(alignment: .topLeading) {
            Color.black
                .opacity(geometry.dim)
                .contentShape(Rectangle())
                // A tap on the page behind answers nothing: the agent waits.
                .onTapGesture {}
                .allowsHitTesting(tray.request != nil && tray.fold < 0.5)
                .accessibilityHidden(true)
            if tray.request != nil, let content = tray.content {
                ApprovalTrayView(tray: tray, content: content, geometry: geometry)
            }
            // Laid out once the tray is up, hidden, so a tap only moves it.
            if let content = tray.content, tray.windowItem != nil || (tray.windowReady && !content.items.isEmpty) {
                if tray.windowItem == nil {
                    // Parked: laid out, not drawn, not there for VoiceOver or a finger.
                    ApprovalWindow(tray: tray, content: content, geometry: geometry).hidden()
                } else {
                    ApprovalWindow(tray: tray, content: content, geometry: geometry)
                }
            }
            if let file = tray.pictureFile {
                ApprovalPicture(tray: tray, file: file, geometry: geometry)
            }
            if tray.request == nil, let words = tray.receiptWords {
                ApprovalReceiptCard(words: words, geometry: geometry)
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topLeading)
        .coordinateSpace(name: ApprovalGeometry.screenSpace)
    }
}

/// Words with no tray before them, on a card the size the tray shrinks to.
struct ApprovalReceiptCard: View {
    let words: String
    let geometry: ApprovalGeometry

    var body: some View {
        Text(words)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Ink.primary)
            .lineLimit(1)
            .padding(.horizontal, ApprovalMetrics.pad)
            .frame(width: geometry.width, height: ApprovalMetrics.receipt)
            .background(Ink.card, in: RoundedRectangle(cornerRadius: ApprovalMetrics.radius, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
            .position(x: geometry.screen.width / 2, y: geometry.bottom - ApprovalMetrics.receipt / 2 + geometry.tray.rise)
            .opacity(geometry.tray.trayFade)
            .allowsHitTesting(false)
            .accessibilityIdentifier("approval.receipt")
    }
}

/// Where everything stands at this frame.
@MainActor
struct ApprovalGeometry {
    static let screenSpace = "approval.screen"
    static let traySpace = "approval.tray"
    let tray: ApprovalTray
    let screen: CGSize
    let safeTop: CGFloat
    private typealias M = ApprovalMetrics

    var width: CGFloat { min(screen.width - 2 * M.inset, M.maxWidth) }
    var x: CGFloat { (screen.width - width) / 2 }
    /// The tray's bottom edge, on the keyboard when it is up.
    var bottom: CGFloat { screen.height - M.inset - tray.lift }
    /// The tallest the tray may be.
    var cap: CGFloat { bottom - safeTop - M.inset }
    var trayHeight: CGFloat { min(M.header + max(0, tray.height), cap) }
    /// What the body may take below the head.
    var bodyCap: CGFloat { cap - M.header }
    /// The tray where it rests, before it rises, is pulled or folds.
    var restRect: CGRect { CGRect(x: x, y: bottom - trayHeight, width: width, height: trayHeight) }
    var trayOffset: CGFloat { tray.rise + tray.drag }
    var behindScale: CGFloat { 1 - M.behindScale * min(1, max(0, tray.win)) }
    var dim: Double {
        guard tray.request != nil else { return 0 }
        let shown = Double(max(0, min(1, 1 - trayOffset / max(1, trayHeight)))) * tray.trayFade
        return (M.dim * shown + M.dimWindow * Double(min(1, max(0, tray.win)))) * Double(1 - min(1, max(0, tray.fold)))
    }

    /// The tray's rect on screen now: risen, pulled, folding.
    var trayRect: CGRect {
        let rest = restRect.offsetBy(dx: 0, dy: trayOffset)
        // Its bottom stays: the top comes down until only the head is left.
        let height = lerp(rest.height, M.receipt, foldShare)
        return CGRect(x: rest.minX, y: rest.maxY - height, width: rest.width, height: height)
    }

    /// A thing measured in the tray's own space, where it is on screen now,
    /// the tray stepping back behind a window included (scaled about its
    /// bottom center, as the tray view does).
    func onScreen(_ key: String) -> CGRect? {
        guard let local = tray.frames[key] else { return nil }
        if key.hasPrefix("win:") { return local }
        let rect = trayRect
        let s = behindScale
        let anchor = CGPoint(x: rect.midX, y: rect.maxY)
        let origin = CGPoint(x: rect.minX + local.minX, y: rect.minY + local.minY)
        return CGRect(x: anchor.x + (origin.x - anchor.x) * s, y: anchor.y + (origin.y - anchor.y) * s,
                      width: local.width * s, height: local.height * s)
    }

    /// The window, open: under the status bar down to the tray's bottom, so
    /// its button stands exactly where the tray's does.
    var windowRect: CGRect {
        let top = safeTop + M.windowTop
        return CGRect(x: x, y: top, width: width, height: bottom - top)
    }

    // MARK: what each piece shows now (the views and the trace read these)

    var foldShare: CGFloat { min(1, max(0, tray.fold)) }
    /// The body and the button fade as the tray shrinks away from them.
    var bodyShown: Double { Double(1 - min(1, max(0, (foldShare - 0.1) / 0.6))) }
    /// The body coming in and the one going out.
    var bodyIn: Double { tray.leaving == nil ? 1 : Double(min(1, max(0, tray.swap))) }
    var bodyOut: Double { tray.leaving == nil ? 0 : Double(1 - min(1, max(0, tray.swap))) }
    var bodyRise: CGFloat { tray.leaving == nil ? 0 : ApprovalMetrics.rise * (1 - min(1, max(0, tray.swap))) }

    /// The row the window grows from, where it is this frame.
    var windowFromRect: CGRect? { geometryFrom(tray.windowFrom) }
    private func geometryFrom(_ key: String) -> CGRect? { onScreen(key) }
    /// The window's rect this frame: between its row and open, pulled down.
    var windowNow: CGRect {
        let open = windowRect
        let from = windowFromRect ?? open
        return lerp(from, open, tray.win).offsetBy(dx: 0, dy: ApprovalMetrics.band(tray.pull))
    }
    var windowScale: CGFloat { 1 - min(0.12, max(0, tray.pull) / 2400) }
    var windowWords: Double { Double(min(1, max(0, (tray.win - 0.08) / 0.3))) }
    var windowGhost: Double { Double(max(0, 1 - tray.win / 0.33)) }
    /// The window's own ground, coming in over the first eighth.
    var windowGround: Double { Double(min(1, max(0, tray.win / 0.3))) }

    /// A file's page this frame: between its thumbnail and as large as it goes.
    func pictureNow(fit: CGRect) -> CGRect {
        let from = onScreen(tray.pictureKey) ?? fit
        let rect = lerp(from, fit, tray.picture)
        let k = 1 - min(0.3, max(0, tray.pictureDrag) / 1200)
        return CGRect(x: rect.midX - rect.width * k / 2, y: rect.minY + tray.pictureDrag, width: rect.width * k, height: rect.height * k)
    }
    var pictureBlack: Double {
        Double(min(1, max(0, tray.picture))) * Double(1 - min(1, max(0, tray.pictureDrag) / 400))
    }

    func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t), width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
    }
}
