import Observation
import SwiftUI
import UIKit
import XCTest
@testable import YabPhone

/// Read the actual dot and glyph pixels so a stopped test clock cannot pass
/// for the shared Reduce Motion test input. This does not toggle the OS
/// preference; ordinary movement is checked through the same renderer.
@MainActor
final class TaskReducedMotionTests: XCTestCase {
    private var window: UIWindow!
    private weak var previousKey: UIWindow?
    private var previousDisabled = false
    private var previousTestReduced = false

    override func setUp() async throws {
        previousDisabled = Motion.disabled
        previousTestReduced = Motion.testPreference.isReduced
        Motion.testPreference.isReduced = false
        Motion.disabled = false
        XCTAssertFalse(Motion.reduced, "ordinary controls need a normal-motion test launch")
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        previousKey = scene?.windows.first(where: \.isKeyWindow)
        window = scene.map { UIWindow(windowScene: $0) }
            ?? UIWindow(frame: CGRect(origin: .zero, size: Metrics.screen))
        window.frame = CGRect(origin: .zero, size: Metrics.screen)
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        previousKey?.makeKey()
        Motion.disabled = previousDisabled
        Motion.testPreference.isReduced = previousTestReduced
    }

    func testStepDoesNotStartPulsingWithTestReduceMotionAlreadyOn() async throws {
        try await initiallyStill(.step)
    }

    func testFaceIDDoesNotStartPulsingWithTestReduceMotionAlreadyOn() async throws {
        try await initiallyStill(.faceID)
    }

    func testStepStopsAndRestartsWhenTestReduceMotionChanges() async throws {
        try await preferenceChanges(.step)
    }

    func testFaceIDStopsAndRestartsWhenTestReduceMotionChanges() async throws {
        try await preferenceChanges(.faceID)
    }

    func testDisabledMotionKeepsBothPulsesStillAcrossTestPreferenceChanges() async throws {
        Motion.disabled = true
        for kind in PulseKind.allCases {
            _ = host(kind, reduced: false)
            let reference = try snapshot(kind).brightness
            Motion.testPreference.isReduced = true
            try await still(kind, expected: reference, name: "\(kind) disabled reduced")
            Motion.testPreference.isReduced = false
            try await still(kind, expected: reference, name: "\(kind) disabled normal")
        }
    }

    func testCompletedStepAndSignedFaceIDStayStillWhenMotionReturns() async throws {
        for kind in PulseKind.allCases {
            let model = host(kind, reduced: false)
            try await moving(kind, name: "\(kind) working")
            Motion.testPreference.isReduced = true
            model.stepKind = .done
            model.faceIDState = .signed
            // First observe the completed content, then change the preference.
            _ = try snapshot(kind)
            await Task.yield()
            Motion.testPreference.isReduced = false
            try await still(kind, name: "\(kind) complete")
        }
    }

    private func initiallyStill(_ kind: PulseKind) async throws {
        let reference = try restingReference(kind)
        _ = host(kind, reduced: true)
        try await arrived(kind, expected: reference)
        try await still(kind, expected: reference, name: "\(kind) initially reduced")
    }

    private func preferenceChanges(_ kind: PulseKind) async throws {
        let reference = try restingReference(kind)
        _ = host(kind, reduced: false)
        try await moving(kind, name: "\(kind) ordinary")
        Motion.testPreference.isReduced = true
        try await arrived(kind, expected: reference)
        try await still(kind, expected: reference, name: "\(kind) reduced while visible")
        Motion.testPreference.isReduced = false
        try await moving(kind, name: "\(kind) resumed")
    }

    private func restingReference(_ kind: PulseKind) throws -> Double {
        let was = Motion.disabled
        Motion.disabled = true
        defer { Motion.disabled = was }
        _ = host(kind, reduced: false)
        return try snapshot(kind).brightness
    }

    @discardableResult
    private func host(_ kind: PulseKind, reduced: Bool) -> PulseModel {
        let model = PulseModel()
        Motion.testPreference.isReduced = reduced
        let controller = UIHostingController(rootView: PulseFixture(kind: kind, model: model))
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return model
    }

    private func arrived(_ kind: PulseKind, expected: Double) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var actual = try snapshot(kind).brightness
        while abs(actual - expected) > 0.2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(1.0 / 60))
            actual = try snapshot(kind).brightness
        }
        XCTAssertEqual(actual, expected, accuracy: 0.2, "the actual pulse must return to its full, still pose")
    }

    private func still(_ kind: PulseKind, expected: Double? = nil, name: String) async throws {
        let samples = try await phases(kind)
        let range = try brightnessRange(samples)
        attach(samples.first!.image, name: "\(name) first")
        attach(samples.last!.image, name: "\(name) last")
        XCTAssertLessThanOrEqual(range, 0.2, "the native pulse pixels must stay still across one full ordinary cycle")
        if let expected {
            for sample in samples { XCTAssertEqual(sample.brightness, expected, accuracy: 0.2) }
        }
    }

    private func moving(_ kind: PulseKind, name: String) async throws {
        let samples = try await phases(kind)
        let range = try brightnessRange(samples)
        let dim = try XCTUnwrap(samples.min { $0.brightness < $1.brightness })
        let bright = try XCTUnwrap(samples.max { $0.brightness < $1.brightness })
        attach(dim.image, name: "\(name) dim")
        attach(bright.image, name: "\(name) bright")
        XCTAssertGreaterThan(range, 1, "ordinary native pulse pixels must move, proving the renderer observes the animation")
    }

    private func phases(_ kind: PulseKind) async throws -> [PulseSample] {
        var samples = [try snapshot(kind)]
        // Sampling one full ordinary cycle catches a pulse that merely
        // passed through its resting pose while Reduce Motion was on.
        for _ in 0..<8 {
            try await Task.sleep(for: .seconds(kind.duration / 4))
            samples.append(try snapshot(kind))
        }
        return samples
    }

    private func brightnessRange(_ samples: [PulseSample]) throws -> Double {
        let values = samples.map(\.brightness)
        return try XCTUnwrap(values.max()) - XCTUnwrap(values.min())
    }

    private func snapshot(_ kind: PulseKind) throws -> PulseSample {
        window.layoutIfNeeded()
        window.rootViewController?.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drawn, "the actual native hierarchy must render")
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        let crop: CGRect
        switch kind {
        case .step:
            let x = center.x + 120 - Metrics.Steps.dotTrailing - Metrics.Steps.dot / 2
            crop = CGRect(x: x - 12, y: center.y - 12, width: 24, height: 24)
        case .faceID:
            let edge = Metrics.Consent.faceID
            crop = CGRect(x: center.x - edge / 2, y: center.y - edge / 2, width: edge, height: edge)
        }
        let cg = try XCTUnwrap(image.cgImage?.cropping(to: crop.integral))
        let width = cg.width
        let height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        XCTAssertTrue(rendered, "the pixel storage must stay alive while CGContext draws")
        var total = 0
        for index in stride(from: 0, to: rgba.count, by: 4) {
            total += Int(rgba[index]) + Int(rgba[index + 1]) + Int(rgba[index + 2])
        }
        return PulseSample(image: image, brightness: Double(total) / Double(width * height * 3))
    }

    private func attach(_ image: UIImage, name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private enum PulseKind: CaseIterable {
    case step, faceID
    var duration: TimeInterval { self == .step ? Motion.stepBeat.duration : Motion.faceIDPulse.duration }
}

@MainActor
@Observable
private final class PulseModel {
    var stepKind: TaskTurns.Row.Kind = .live
    var faceIDState: TaskDesk.FaceIDState = .looking
}

private struct PulseSample {
    let image: UIImage
    let brightness: Double
}

private struct PulseFixture: View {
    let kind: PulseKind
    let model: PulseModel

    var body: some View {
        Group {
            switch kind {
            case .step:
                StepRow(row: .init(icon: "", text: "Running", kind: model.stepKind))
                    .frame(width: 240, height: 80)
            case .faceID:
                FaceIDPanel(state: model.faceIDState)
                    .frame(width: 240, height: 240)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .ignoresSafeArea()
    }
}
