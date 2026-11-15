import AVFoundation
import XCTest
@testable import YabPhone

@MainActor
final class AttachMediaTests: XCTestCase {
    func testCameraOnlyRunsInVisibleAuthorizedTrayAndReleasesOnEveryExit() {
        var authorization = AVAuthorizationStatus.authorized
        var runs: [Bool] = []
        let camera = AttachCamera(authorization: { authorization }, available: { true }, run: { runs.append($0) })
        camera.update(visible: false)
        XCTAssertEqual(runs, [])
        camera.update(visible: true)
        camera.update(visible: true)
        XCTAssertEqual(runs, [true])
        camera.update(visible: false)
        camera.update(visible: true)
        authorization = .denied
        camera.update(visible: true)
        XCTAssertEqual(runs, [true, false, true, false])
        XCTAssertEqual(camera.status, .denied)
        authorization = .authorized
        camera.update(visible: true)
        XCTAssertEqual(runs.last, true, "returning from Settings refreshes permission")
    }

    func testOpeningDoesNotRequestPermissionAndRestrictionNeverStartsCapture() async {
        var authorization = AVAuthorizationStatus.notDetermined
        var requests = 0
        var runs: [Bool] = []
        let camera = AttachCamera(authorization: { authorization }, available: { true }, request: {
            requests += 1
            authorization = .authorized
            return true
        }, run: { runs.append($0) })
        camera.update(visible: true)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(runs, [])
        camera.update(visible: false)
        let granted = await camera.requestIfNeeded()
        XCTAssertTrue(granted)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(runs, [], "permission granted during handover must not start a hidden camera")
        authorization = .restricted
        camera.update(visible: true)
        let restricted = await camera.requestIfNeeded()
        XCTAssertFalse(restricted)
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(runs, [])
    }

    func testPermissionResolvedAfterDismissalDoesNotRestartTheCamera() async {
        var authorization = AVAuthorizationStatus.notDetermined
        var continuation: CheckedContinuation<Bool, Never>?
        var runs: [Bool] = []
        let camera = AttachCamera(authorization: { authorization }, available: { true }, request: {
            await withCheckedContinuation { continuation = $0 }
        }, run: { runs.append($0) })
        camera.update(visible: true)
        let pending = Task { await camera.requestIfNeeded() }
        while continuation == nil { await Task.yield() }
        camera.update(visible: false)
        authorization = .authorized
        continuation?.resume(returning: true)
        _ = await pending.value
        XCTAssertFalse(camera.running)
        XCTAssertEqual(runs, [])
    }

    func testUnavailableCameraDoesNotAskOrStartCapture() async {
        var requests = 0
        var runs: [Bool] = []
        let camera = AttachCamera(authorization: { .authorized }, available: { false }, request: {
            requests += 1
            return true
        }, run: { runs.append($0) })
        camera.update(visible: true)
        let allowed = await camera.requestIfNeeded()
        XCTAssertFalse(allowed)
        XCTAssertEqual(camera.status, .unavailable)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(runs, [])
    }
}
