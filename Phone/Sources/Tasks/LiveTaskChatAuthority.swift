import SwiftUI
import SyncKit
import Observation
import Foundation

/// Each rendered result captures its own public task and presentation turn.
/// Old links cannot borrow a reopened chat, account, engine or later result.
@MainActor
final class LiveTaskChatAuthority {
    private weak var app: AppModel?
    private weak var engine: PhoneSync?
    private let account: String?
    private let space: Space.ID
    private let generation: Int
    private let lease = PresentationLease()
    let snapshot: LiveTaskSnapshot

    init(app: AppModel, snapshot: LiveTaskSnapshot) {
        self.app = app
        engine = app.sync.engine
        account = app.sync.engine?.seal.account
        space = app.browser.spaceID
        generation = app.taskDesk.liveChatGeneration
        self.snapshot = snapshot
        // Retire synchronously on withdrawal, including source -> another
        // surface -> source before an actor callback could notice the change.
        let lease = self.lease
        withObservationTracking {
            _ = app.sync.engine
            _ = app.browser.spaceID
            _ = app.hasPrivateForeground
            _ = app.privateLock.isActive
            _ = app.surfaces.chat
            _ = app.surfaces.field
            _ = app.surfaces.menu
            _ = app.surfaces.settings
            _ = app.surfaces.join
            _ = app.chatSheet.shown
            _ = app.taskDesk.sheet
            _ = app.taskDesk.faceID
        } onChange: { lease.retire() }
    }

    /// Closing owns the presentation, not a particular progress/result revision.
    var presentationCurrent: Bool {
        guard !lease.retired, let app, let engine, app.sync.engine === engine,
              engine.seal.account == account, app.browser.spaceID == space,
              app.taskDesk.liveChatGeneration == generation,
              app.surfaces.chat == .task(snapshot.id), !app.chatSheet.shown,
              app.surfaces.field == nil, app.surfaces.menu == nil,
              app.taskDesk.sheet == nil, app.taskDesk.faceID == nil,
              !app.surfaces.settings, !app.surfaces.join,
              app.sync.visibleLiveTask(snapshot.id)?.request == snapshot.request else { return false }
        return true
    }

    /// Links remain bound to the exact rendered result after the broader
    /// presentation ownership check. A new result never borrows an old link.
    var current: Bool {
        presentationCurrent && app?.sync.visibleLiveTask(snapshot.id) == snapshot
    }

    func close() {
        guard presentationCurrent else { return }
        app?.taskDesk.foldChat()
    }

    func open(_ url: URL) -> OpenURLAction.Result {
        guard current, let app, let target = OpenOnMac.url(url.absoluteString),
              let host = target.host else { return .discarded }
        let tab = Tab(id: UUID().uuidString, title: host, site: host, icon: host,
                      url: target.absoluteString, isPrivate: false)
        app.surfaces.closeChat()
        app.taskDesk.dismissForLink()
        app.taskDesk.restorePageAfterChat()
        app.browser.open(tab)
        return .handled
    }

    private nonisolated final class PresentationLease: @unchecked Sendable {
        private let lock = NSLock()
        private var invalid = false
        func retire() { lock.lock(); invalid = true; lock.unlock() }
        var retired: Bool { lock.lock(); defer { lock.unlock() }; return invalid }
    }
}
