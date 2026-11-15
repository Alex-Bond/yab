import Foundation
import SyncKit

extension LiveTaskSnapshot {
    var nowPriority: Int {
        switch observation?.status {
        case .needsYou?, .failed?: 0
        case .running?: 1
        case .waits?, nil: 2
        case .done?: 3
        case .stopped?: 4
        }
    }
}

extension NowItem {
    /// Read-only task records carry no code, payment, Retry or remote-control actions.
    static func live(_ snapshot: LiveTaskSnapshot) -> NowItem {
        var item = NowItem(id: snapshot.id, kind: .plain, title: snapshot.title,
                           subtitle: snapshot.progress, action: nil, short: "Task",
                           icon: .glyph(.macbook), more: nil)
        switch snapshot.observation?.status {
        case nil: item.kind = .wait; item.short = "Queued"
        case .running?: item.short = "Working"
        case .needsYou?: item.kind = .warn; item.short = "Needs you"
        case .waits?: item.kind = .wait; item.short = "Waits"
        case .failed?: item.kind = .warn; item.short = "Failed"
        case .done?: item.kind = .done; item.short = "Done"
        case .stopped?: item.short = "Stopped"
        }
        item.noticeRevision = snapshot.observation?.revision
        return item
    }
}
