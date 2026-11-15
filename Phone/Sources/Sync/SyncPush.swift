import Foundation
import UIKit
import os
#if canImport(SyncKit)
import SyncKit
#endif

/// Silent pushes from the sync server (R2): while Yab is in the back its line
/// is closed, and when another device changes something the server asks
/// APNs to wake it; the line opens, catches up, sends what waited and closes
/// again, so the column is current the moment Yab is opened. APNs answers
/// the app delegate, not the scene the bridge lives in: the two meet here.
/// A push is a hint, never relied on: coming to the front catches up anyway.
@MainActor
enum SyncPush {
    /// This launch's bridge, once it has a key.
    static weak var bridge: SyncBridge?
    private static var openedApproval: String?
    static func openApproval(_ id: String) {
        if let bridge { bridge.openAssistantApproval(id) } else { openedApproval = id }
    }
    static func takeOpenedApproval() -> String? {
        defer { openedApproval = nil }
        return openedApproval
    }

    /// The token APNs gave, kept until the bridge wants it.
    private(set) static var token: Data?
    private static let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "sync")

    /// Development builds get their pushes from APNs' sandbox.
    static var environment: String {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }

    static func registered(_ token: Data) {
        self.token = token
        bridge?.pushTokenArrived(token)
    }

    static func failed(_ error: Error) {
        log.info("no silent pushes: \(String(describing: error), privacy: .public)")
    }

    /// A silent push: the bridge catches up; with no bridge (a launch in the
    /// back has no scene), the journal does, on its own, for the next launch.
    static func woke(_ done: @escaping (UIBackgroundFetchResult) -> Void) {
        if let bridge { return bridge.wokenByPush(done) }
        guard let setup = SyncBridge.Setup.resolve(options: LaunchOptions.current), let seal = setup.keys.local,
              let deviceID = try? setup.keys.savedDeviceID(),
              let engine = try? PhoneSync(seal: seal, options: .init(base: setup.base, folder: setup.folder,
                                                                     device: .init(id: deviceID, name: setup.deviceName,
                                                                                   model: PhoneSync.model)),
                                          keys: setup.keys)
        else { return done(.noData) }
        headless = engine
        engine.catchUp(closeAfter: true) { came in
            // A Mac's question that came: said now, with no scene to show
            // its card (the server's alert, when there was one, said it
            // already under the same id).
            let questions = engine.assistantApprovals()
            DispatchQueue.main.async {
                guard engine.assistantApprovalsReady else {
                    if headless === engine { headless = nil }
                    done(.noData)
                    return
                }
                ApprovalNotice.reconcile(questions) {
                    if headless === engine { headless = nil }
                    done(came ? .newData : .noData)
                }
            }
        }
    }

    /// The engine of a launch in the back, while it catches up.
    private static var headless: PhoneSync?

    /// The app's own engine starts: one line per device, so the other stops.
    static func letGo() {
        headless?.stop()
        headless = nil
    }
}
