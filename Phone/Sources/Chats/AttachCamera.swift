import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Permission is refreshed on returning from Settings. Only a visible tray may run capture.
@MainActor
@Observable
final class AttachCamera {
    enum Status: Equatable { case notDetermined, authorized, denied, restricted, unavailable }
    private(set) var status: Status = .notDetermined
    private(set) var running = false
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var failed = false
    @ObservationIgnored private let authorization: () -> AVAuthorizationStatus
    @ObservationIgnored private let available: () -> Bool
    @ObservationIgnored private let request: () async -> Bool
    @ObservationIgnored private let run: ((Bool) -> Void)?
    @ObservationIgnored private lazy var capture = AttachCameraCapture { [weak self] in
        guard let self else { return }
        self.failed = true
        self.update(visible: self.visible)
    }

    var session: AVCaptureSession { capture.session }

    init(authorization: @escaping () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .video) },
         available: @escaping () -> Bool = { UIImagePickerController.isSourceTypeAvailable(.camera) },
         request: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .video) },
         run: ((Bool) -> Void)? = nil) {
        self.authorization = authorization
        self.available = available
        self.request = request
        self.run = run
    }

    func update(visible: Bool) {
        self.visible = visible
        // A temporary capture failure can recover the next time the tray opens.
        if !visible { failed = false }
        if !available() { status = .unavailable }
        else {
            switch authorization() {
            case .authorized: status = failed ? .unavailable : .authorized
            case .notDetermined: status = .notDetermined
            case .restricted: status = .restricted
            default: status = .denied
            }
        }
        let next = visible && status == .authorized
        guard next != running else { return }
        running = next
        if let run { run(next) } else { capture.setRunning(next) }
    }

    func requestIfNeeded() async -> Bool {
        update(visible: visible)
        if status == .notDetermined {
            _ = await request()
            update(visible: visible)
        }
        return status == .authorized
    }

    func stop() async {
        update(visible: false)
        if run == nil { await capture.settled() }
    }
}

/// Configuration and the blocking start/stop calls stay on one serial queue.
private final class AttachCameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "yab.attach-camera")
    private let onFailure: @MainActor @Sendable () -> Void

    init(onFailure: @escaping @MainActor @Sendable () -> Void) { self.onFailure = onFailure }

    func setRunning(_ running: Bool) {
        queue.async { [self] in
            guard running else {
                if session.isRunning { session.stopRunning() }
                // Release the camera before the full-screen picker takes it.
                session.beginConfiguration()
                session.inputs.forEach { session.removeInput($0) }
                session.commitConfiguration()
                return
            }
            if session.inputs.isEmpty {
                guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: device) else { return fail() }
                session.beginConfiguration()
                session.sessionPreset = .photo
                guard session.canAddInput(input) else { session.commitConfiguration(); return fail() }
                session.addInput(input)
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
            if !session.isRunning { fail() }
        }
    }

    private func fail() { Task { @MainActor [onFailure] in onFailure() } }

    func settled() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    deinit {
        let session = session
        queue.async { if session.isRunning { session.stopRunning() } }
    }
}

private struct AttachCameraSurface: UIViewRepresentable {
    let session: AVCaptureSession
    final class Surface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.isUserInteractionEnabled = false
        view.preview.videoGravity = .resizeAspectFill
        view.preview.session = session
        return view
    }
    func updateUIView(_ view: Surface, context: Context) { view.preview.session = session }
    static func dismantleUIView(_ view: Surface, coordinator: ()) { view.preview.session = nil }
}

struct AttachCameraTile: View {
    @Environment(AppModel.self) private var app
    // The app uses UIKit's scene delegate, not a SwiftUI App/Scene lifecycle.
    @State private var appActive = UIApplication.shared.applicationState == .active
    @State private var camera = AttachCamera()
    @State private var asking = false
    @State private var pendingCapture: (chat: Chat.ID, generation: UUID)?
    let open: () -> Void

    private var menuVisible: Bool {
        let sheet = app.chatSheet
        return sheet.attachMenu && sheet.attachPage == .main && sheet.shown && !sheet.attachLibrary
            && !sheet.attachCamera && !sheet.attachFiles
    }
    private var visible: Bool { menuVisible && appActive && !asking && pendingCapture == nil }
    private var fixture: AttachCamera.Status? { app.isFixture ? AttachStandIns.camera : nil }
    private var status: AttachCamera.Status { fixture ?? camera.status }

    var body: some View {
        Button {
            guard !asking else { return }
            Haptics.play(.light, reason: Haptics.Reason.menu)
            guard let id = app.chatSheet.chatID else { return }
            if fixture != nil { open(); return }
            let generation = app.chatSheet.attachGeneration
            pendingCapture = (id, generation)
            asking = true
            camera.update(visible: false)
            Task { @MainActor in
                await camera.stop()
                let allowed = await camera.requestIfNeeded()
                asking = false
                guard menuVisible, app.chatSheet.chatID == id,
                      app.chatSheet.attachGeneration == generation else { pendingCapture = nil; return }
                if allowed {
                    openCaptureIfReady()
                } else {
                    pendingCapture = nil
                    app.say(status == .unavailable ? "No camera available" : "Camera is off for Yab in Settings", glyph: .camera1)
                }
            }
        } label: {
            ZStack {
                ChatInk.fill(0.08)
                if status == .authorized {
                    if fixture != nil, let image = AttachStandIns.photos.first {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        AttachCameraSurface(session: camera.session)
                    }
                    Image(systemName: "camera.fill")
                        .font(.system(size: Metrics.Chats.attachCameraSymbol))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, Metrics.Chats.attachMediaGap)
                } else {
                    VStack(spacing: Metrics.Chats.attachMediaGap) {
                        Image(systemName: "camera").font(.system(size: Metrics.Chats.attachCameraSymbol))
                        Text("Camera").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Ink.primary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.Chats.attachMediaHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Chats.trayCard, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chat.attachTray.camera")
        .accessibilityLabel("Camera")
        .accessibilityValue(status == .authorized ? "Live preview" : "Open camera")
        .onAppear { appActive = UIApplication.shared.applicationState == .active }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            appActive = false
            camera.update(visible: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            appActive = true
            openCaptureIfReady()
        }
        .onChange(of: app.chatSheet.attachMenu) { _, open in if !open { pendingCapture = nil } }
        .task(id: visible) { camera.update(visible: visible && fixture == nil) }
        .onDisappear { pendingCapture = nil; camera.update(visible: false) }
    }

    private func openCaptureIfReady() {
        guard let pending = pendingCapture, !asking else { return }
        guard menuVisible, app.chatSheet.chatID == pending.chat,
              app.chatSheet.attachGeneration == pending.generation else { pendingCapture = nil; return }
        // A camera permission sheet temporarily resigns active. Present after UIKit returns.
        guard UIApplication.shared.applicationState == .active else { return }
        pendingCapture = nil
        open()
    }
}
