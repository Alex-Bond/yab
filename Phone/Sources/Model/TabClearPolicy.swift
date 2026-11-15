import Foundation

/// No missing observation is evidence that a tab is disposable.
enum TabClearPolicy {
    enum Reason: String, Codable, Sendable { case current, retained, remoteUnknown, activityUnknown, active, draft, task, pageUnknown, pageBusy }
    struct Clock: Codable, Equatable, Sendable {
        let date: Date
        let uptime: TimeInterval
        static var now: Clock { Clock(date: Date(), uptime: ProcessInfo.processInfo.systemUptime) }
        /// Both clocks must agree in this boot. Reboots and clock corrections protect.
        func elapsed(since old: Clock) -> TimeInterval? {
            let wall = date.timeIntervalSince(old.date), monotonic = uptime - old.uptime
            guard old.uptime >= 0, uptime >= 0, wall >= 0, monotonic >= 0, abs(wall - monotonic) <= 2 else { return nil }
            return min(wall, monotonic)
        }
    }
    struct Activity: Codable, Equatable, Sendable {
        var space: Space.ID
        var address: String?
        var last: Clock
        var localOnly: Bool
    }
    /// Clear pressed by a person, as the Mac's: today's tabs go but the one
    /// in front, what is kept or pinned, the Mac's own, an unsent draft and
    /// a task's. Shared or unobserved is no reason to stay when someone asks;
    /// a page still alive is asked again (WebPool.clearProof), and Undo
    /// brings the batch back.
    static func protectManual(_ tab: Tab, in space: Space, draft: Bool, task: Bool) -> Reason? {
        if tab.id == space.current { return .current }
        if tab.place != .today || space.pins.contains(where: { $0.id == tab.id }) || space.keptTabs.contains(where: { $0.id == tab.id }) { return .retained }
        if tab.onMac { return .remoteUnknown }
        if draft { return .draft }
        if task { return .task }
        return nil
    }

    static func protect(_ tab: Tab, in space: Space, activity: Activity?, now: Clock,
                        automatic: Bool, authorityLocal: Bool, draft: Bool, task: Bool) -> Reason? {
        if tab.id == space.current { return .current }
        if tab.place != .today || space.pins.contains(where: { $0.id == tab.id }) || space.keptTabs.contains(where: { $0.id == tab.id }) { return .retained }
        if tab.onMac || (!space.isPrivate && (!authorityLocal || activity?.localOnly != true)) { return .remoteUnknown }
        if draft { return .draft }
        if task { return .task }
        guard let activity, activity.space == space.id, activity.address == tab.url,
              let age = now.elapsed(since: activity.last) else { return .activityUnknown }
        if automatic && age < 12 * 60 * 60 { return .active }
        return nil
    }
}
