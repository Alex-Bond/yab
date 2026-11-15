import AVFoundation
import SwiftUI
import UIKit
import VisionKit
#if canImport(SyncKit)
import SyncKit
#endif

/// The QR code scanner, from the right button's menu (Scan QR Code, after
/// New Chat) on iPhones that can scan (VisionKit's DataScannerViewController):
/// New Tab's field opens under the camera, which is asked for only now, the
/// first time. The camera fills the screen with a word and ✕ over it; the
/// first code found closes it: a web address opens in a new tab, as Paste and
/// Go does (a private one from Private), anything else goes into the field as
/// words to search, ask or edit.
@MainActor
@Observable
final class CodeScanner {
    /// What a code is to the field.
    enum Route: Equatable, Sendable {
        case open(URL)
        case words(String)
        case nothing
    }

    /// The camera is up.
    var shown = false
    /// This iPhone can scan (or a test's stand-in camera stands in).
    private(set) var canScan: Bool
    /// Test runs: what the stand-in camera finds, and whether it waits.
    private(set) var standIn: String?
    var standInWaits = false

    @ObservationIgnored private weak var app: AppModel?
    /// What the field does once the camera has gone.
    @ObservationIgnored private var afterClose: (@MainActor () -> Void)?

    init(app: AppModel?, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.app = app
        var payload: String?
        if LaunchOptions.current.isTestRun, let i = arguments.firstIndex(of: "-YabScan"), i + 1 < arguments.count {
            payload = arguments[i + 1]
        }
        standIn = payload
        canScan = payload != nil || DataScannerViewController.isSupported
    }

    /// Named states and tests: a stand-in camera that finds `payload`.
    func useStandIn(_ payload: String, waits: Bool = false) {
        standIn = payload
        standInWaits = waits
        canScan = true
    }


    // MARK: - the camera

    func open() {
        guard let app, canScan, !shown, app.field.mode == .newTab else { return }
        Haptics.play(.soft, reason: Haptics.Reason.scan)
        if standIn != nil { return present() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            present()
        case .notDetermined:
            Task { @MainActor [weak self] in
                if await AVCaptureDevice.requestAccess(for: .video) { self?.present() } else { self?.cameraOff() }
            }
        default:
            cameraOff()
        }
    }

    private func present() {
        afterClose = { [weak app] in app?.field.ask() }
        shown = true
    }

    private func cameraOff() {
        app?.say("Camera is off for Yab in Settings", glyph: .qrCode)
    }

    /// ✕: back to the field, its keyboard with it.
    func close() {
        guard shown else { return }
        shown = false
    }

    /// A code: the camera goes, then the field does what it says.
    func found(_ payload: String) {
        guard shown, let app else { return }
        Haptics.play(.success, reason: Haptics.Reason.scanned)
        // A Mac's Add a Device code (yab://join/…) joins sync, as Join Your
        // Mac's own Scan QR does (SyncBridge.openJoinLink).
        if let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)), JoinInvite.code(scanned: payload) != nil,
           url.scheme?.lowercased() == "yab" {
            afterClose = { [weak app] in _ = app?.sync.openJoinLink(url) }
            shown = false
            return
        }
        switch Self.route(payload) {
        case let .open(url):
            afterClose = { [weak app] in app?.openScanned(url) }
        case let .words(words):
            afterClose = { [weak app] in app?.field.put(words) }
        case .nothing:
            break
        }
        shown = false
    }

    /// The camera's cover has gone.
    func closed() {
        let then = afterClose
        afterClose = nil
        then?()
    }

    // MARK: - what a code is

    /// A web address (with its scheme, or a bare one like example.com)
    /// opens; any other text is words for the field, on one line; nothing
    /// is nothing. Other schemes (mailto, a Wi-Fi network, a script) are
    /// words too: a code never makes Yab do more than a typed line would.
    static func route(_ payload: String) -> Route {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .nothing }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           url.host() != nil {
            return .open(url)
        }
        let lower = text.lowercased()
        if !text.contains("://"), !lower.hasPrefix("about:"), !lower.hasPrefix("data:"),
           let url = Words.address(text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return .open(url)
        }
        let line = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return .words(String(line.prefix(500)))
    }
}

extension AppModel {
    /// The right button's Scan QR Code: New Tab's field, the camera over it.
    func openScanner(from origin: CGRect? = nil) {
        openNewTab(from: origin) { [weak self] in self?.scanner.open() }
    }

    /// A scanned address: a new tab, as Paste and Go opens one; private
    /// from a private New Tab.
    func openScanned(_ url: URL) {
        let isPrivate = field.place.isPrivate
        adoptNewTabSpace()
        field.forget()
        closeFieldAfterChoice()
        show(PageFixtures.tab(for: url, isPrivate: isPrivate, in: world, fixturesEnabled: fixturesEnabled), newTab: true)
    }
}

extension Haptics.Reason {
    static let scan = "scan"
    static let scanned = "scanned"
}

/// The camera over everything: VisionKit's scanner (or the tests' stand-in),
/// a word at the foot, ✕ in its glass circle at the top right.
struct CodeScannerCover: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let scanner = app.scanner
        ZStack {
            Color.black.ignoresSafeArea()
            if let payload = scanner.standIn {
                StandInCamera(payload: payload, waits: scanner.standInWaits) { scanner.found($0) }
            } else {
                DataScannerView { scanner.found($0) }
                    .ignoresSafeArea()
            }
            VStack {
                HStack {
                    Spacer()
                    Button { scanner.close() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Color.white)
                            .frame(width: Metrics.Field.close, height: Metrics.Field.close)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.tint(Color.black.opacity(0.3)).interactive(), in: Circle())
                    .accessibilityIdentifier("scan.close")
                    .accessibilityLabel("Close")
                }
                Spacer()
                Text("Point at a QR code")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassEffect(.regular.tint(Color.black.opacity(0.3)), in: Capsule(style: .continuous))
                    .accessibilityIdentifier("scan.hint")
            }
            .padding(.horizontal, Metrics.Edge.bar)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scan.camera")
        .accessibilityAction(.escape) { scanner.close() }
    }
}

/// VisionKit's scanner, QR codes only, the first one found handed on.
private struct DataScannerView: UIViewControllerRepresentable {
    let found: @MainActor (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.found = found
        guard !scanner.isScanning else { return }
        // In its window by the next turn.
        DispatchQueue.main.async { try? scanner.startScanning() }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var found: @MainActor (String) -> Void
        private var done = false

        init(found: @escaping @MainActor (String) -> Void) { self.found = found }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            take(addedItems)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            take([item])
        }

        private func take(_ items: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case let .barcode(code) = item, let payload = code.payloadStringValue, !payload.isEmpty {
                    done = true
                    found(payload)
                    return
                }
            }
        }
    }
}

/// The simulator has no camera: a dark frame with the code's corners, that
/// finds its payload a moment after it opens (or waits, for pictures).
private struct StandInCamera: View {
    let payload: String
    let waits: Bool
    let found: @MainActor (String) -> Void

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Glyph(.qrCode, size: 160, color: Color.white.opacity(0.18))
        }
        .accessibilityElement()
        .accessibilityIdentifier("scan.standIn")
        .accessibilityLabel("Camera")
        .task {
            guard !waits else { return }
            try? await Task.sleep(for: .milliseconds(700))
            found(payload)
        }
    }
}
