import Foundation
import UIKit

/// New Tab's field with the keyboard up as Yab opens (request 1086): on a
/// cold launch and when Yab comes back with no tab open; back to a running
/// app with a page in front, the page stays. Settings › General › Open
/// Keyboard at Launch turns it off.
///
/// Yab adds one thing: a cold launch right after iOS ended Yab in the
/// background, into a page left scrolled down, keeps that page. The person
/// was reading it a moment ago.
enum LaunchKeyboard {
    enum Moment: Equatable {
        /// The process started.
        case launch
        /// Back from the background to a Yab still running.
        case back
    }

    struct Situation: Equatable {
        var moment: Moment
        /// Settings › General › Open Keyboard at Launch.
        var enabled = true
        /// Launched or brought back for something: a link, a widget, a
        /// notification, a page from the Mac, a named state.
        var asked = false
        /// The welcome stands over the app (Welcome/FirstRun).
        var welcome = false
        /// The page in front is private: no Face ID ask the person didn't start.
        var privateFront = false
        /// Something already stands over the page: the field, a chat,
        /// Settings, Join, a menu.
        var covered = false
        /// A tab is in front of the space.
        var hasTab = true
        /// How far down the page in front was left, in points.
        var scrolled: Double = 0
        /// Since Yab last went to the background; nil when unknown.
        var away: TimeInterval?
    }

    /// Past this far down, the page in front was being read.
    static let readingDepth: Double = 200
    /// A page being read is kept on a launch this soon after Yab went away.
    static let readingHold: TimeInterval = 15 * 60

    static func opens(_ s: Situation) -> Bool {
        guard s.enabled, !s.asked, !s.welcome, !s.privateFront, !s.covered else { return false }
        guard s.hasTab else { return true }
        switch s.moment {
        case .back:
            return false
        case .launch:
            let reading = s.scrolled > readingDepth
            if reading, let away = s.away, away < readingHold { return false }
            return true
        }
    }

    // MARK: - when Yab went away

    static let leftKey = "launch.leftAt"

    /// Written as Yab goes to the background, read at the next launch.
    static func left(at date: Date = Date(), in defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: leftKey)
    }

    static func away(now: Date = Date(), in defaults: UserDefaults = .standard) -> TimeInterval? {
        guard defaults.object(forKey: leftKey) != nil else { return nil }
        let left = Date(timeIntervalSinceReferenceDate: defaults.double(forKey: leftKey))
        return max(0, now.timeIntervalSince(left))
    }
}

extension AppModel {
    /// What the rule reads of the app as it comes to the front.
    func launchKeyboardSituation(_ moment: LaunchKeyboard.Moment, asked: Bool, away: TimeInterval?) -> LaunchKeyboard.Situation {
        let tab = browser.tab
        var scrolled: Double = 0
        if let tab, let state = pages.navigationState(for: tab.id),
           state.entries.indices.contains(state.index) {
            scrolled = state.entries[state.index].scrollY
        }
        return LaunchKeyboard.Situation(
            moment: moment,
            enabled: SettingsStore.shared.openKeyboardAtLaunch,
            asked: asked,
            welcome: FirstLaunch.shows(self),
            privateFront: browser.space.isPrivate || tab?.isPrivate == true,
            covered: surfaces.field != nil || surfaces.chat != nil || chatSheet.shown || surfaces.settings
                || surfaces.join || surfaces.menu != nil,
            hasTab: tab != nil,
            scrolled: scrolled,
            away: away)
    }

    /// The search sheet over the page, its keyboard up, standing from the
    /// first frame: no growth out of the plate after the page has shown.
    func openLaunchField() {
        // Nothing in the stack: a pin left in front gives way to the empty screen.
        if let front = browser.tab, front.place != .today, TabStack.of(self).order.count <= 1, !browser.space.isPrivate {
            browser.letGo(of: front.id)
        }
        chrome.setFolded(false)
        field.openNewTabInPlace()
    }
}
