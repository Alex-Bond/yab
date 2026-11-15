import Observation
import SwiftUI
import UIKit

/// What a held or swiped tab does on the spaces (Field/NewTabSpaces): Pin,
/// Unpin, Keep, Unkeep, Move to Space and Close, here and on the Mac. The spaces, tabs
/// and folders are BrowserStore's; this only says how they change.
@MainActor
@Observable
final class ColumnState {
    /// Held for good: one per app, and an app lives as long as the process.
    @ObservationIgnored let app: AppModel

    init(app: AppModel) {
        self.app = app
    }

    // MARK: - one per app

    private static var states: [ObjectIdentifier: ColumnState] = [:]

    static func of(_ app: AppModel) -> ColumnState {
        let key = ObjectIdentifier(app)
        if let state = states[key] { return state }
        let state = ColumnState(app: app)
        states[key] = state
        return state
    }

    // MARK: - a tab's actions

    /// Close: the row folds its height away, then the tab is gone; the one in
    /// front goes to the first of today (or the first row, or the first pin).
    /// The toast offers it back, its pages and place with it (Back/BackStack).
    func close(_ id: Tab.ID) {
        if app.sync.changeDetachedSharedPin(id, close: true) { return }
        guard let owner = app.browser.space(holding: id) else { return }
        Haptics.play(.light, reason: Haptics.Reason.closed)
        let wasFront = owner.current == id
        let closed = app.backStack.remember(id)
        // The row leaves the data at once, inside the animation: the native
        // List folds the cell away itself, as Mail's full swipe does. A
        // SwiftUI height fold first never reached the List's cell, so the
        // row stood still for the fold and then vanished in one frame.
        Motion.rowFold.run {
            app.browser.close(id)
            if wasFront, let next = app.browser.space(owner.id)?.today.first {
                app.browser.select(next.id)
            }
        }
        app.pages.forget(id)
        if let closed, app.browser.tab(id) == nil { app.backStack.offer(closed) }
    }

    /// Keep: the tab goes up to the end of the kept, here and on the Mac.
    func keep(_ id: Tab.ID) {
        Haptics.play(.light, reason: Haptics.Reason.kept)
        Motion.columnRows.run { app.browser.keep(id) }
    }

    /// Unkeep: the tab goes down to the top of today's.
    func unkeep(_ id: Tab.ID) {
        Haptics.play(.light, reason: Haptics.Reason.unkept)
        Motion.columnRows.run { app.browser.unkeep(id) }
    }

    /// Pin: the tab goes up into the space's pins, at their end, as the
    /// Mac pins it, here and on the Mac.
    func pin(_ id: Tab.ID) {
        Haptics.play(.light, reason: Haptics.Reason.pinned)
        Motion.columnRows.run { app.browser.pin(id) }
    }

    /// Unpin: the pin goes down to the top of today's.
    func unpin(_ id: Tab.ID) {
        if app.sync.changeDetachedSharedPin(id) { return }
        Haptics.play(.light, reason: Haptics.Reason.unpinned)
        Motion.columnRows.run { app.browser.unpin(id) }
    }

    /// Move to Space: first of that space's today.
    func move(_ id: Tab.ID, to target: Space.ID) {
        if app.sync.changeDetachedSharedPin(id, to: target) { return }
        guard let name = app.browser.space(target)?.name else { return }
        Haptics.play(.light, reason: Haptics.Reason.moved)
        Motion.columnRows.run { app.browser.move(id, to: target) }
        app.say("Moved to \(name)", glyph: .arrowRight)
    }
}
