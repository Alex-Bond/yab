import Foundation
import UIKit
import os

/// What the finger feels, one function for all of it: only what changes a
/// state or needs attention. Frequent paths (plate, field, answers,
/// scrolling) stay quiet.
///
/// Louder, picked by finger on 2026-10-09 from four styles side by side
/// (https://claude.ai/artifact/7g7XgjzWKJWe6Cbum79cRJ): every impact is a soft
/// one, round, never a rigid knock, at its moment's tone, 0.55 to 1.0 strong
/// (`Feel`); selection ticks are soft impacts too, since iOS's own can't be
/// made stronger; only outcomes are iOS's success, warning and error. The
/// 2026-10-08 system played the same soft impacts at 0.3 to 0.9, too weak
/// through a case. Swipes are felt where the finger decides them (Pager,
/// BackStack, TabStack), not as they land. Callers still say a kind, so the
/// journal tests keep reading what the caller meant.
///
/// In test runs every call is also written, one line each, to a journal the
/// UI tests read back to check the sequence: the file named by the
/// environment variable YAB_HAPTICS_JOURNAL, else Library/Caches/yab-haptics.log
/// in the app's container. A line is `<seconds since launch> <kind> <reason>`.
enum Haptics {
    enum Kind: String, CaseIterable, Sendable {
        case soft, selection, light, medium, rigid, warning, success, error
    }

    /// What a moment is, so moments alike feel alike.
    enum Tone: String, CaseIterable, Sendable {
        /// Something passed under the finger or was decided: 0.7.
        case tick
        /// The finger's action worked: 0.9.
        case tap
        /// A big change made by the finger: 1.0.
        case thud
        /// No further (the first tab, nothing back, a limit): 0.55.
        case wall
        /// Nothing found: 0.55, twice.
        case wallTwice
        case success, warning, error
    }

    /// The prototype's moments, so callers say which one they are. The tone
    /// each one plays is `tone(_:_:)`'s.
    enum Reason {
        static let eyes = "eyes"                 // Private's eyes
        static let reload = "reload"             // Reload or Stop, Back, Forward
        static let privateUnlocked = "private unlocked" // the lock in Private's New Tab opens
        static let spaceUnderLens = "space"      // a space passes under the lens
        static let columnOpened = "column"       // the spaces come up from the plate
        static let menu = "menu"                 // the plate's ⋯, a held chat
        static let clear = "clear"               // Clear
        static let tabHeld = "hold"
        static let tabLifted = "lift"
        static let rowAction = "row"             // Close, Keep, Unkeep; a folder opens
        static let swipeThreshold = "threshold"  // a long swipe will act
        static let chatAction = "chat"
        static let appIconPreview = "icon preview" // a new Cover Flow choice
        static let appIconUse = "icon use"         // one accepted native icon request
        static let confirm = "confirm"           // Keep, let go, send
        static let needsYou = "needs you"        // warning
        static let done = "done"                 // success
        static let paid = "paid"                 // success: a payment the site took
        static let failed = "failed"             // error
        static let detent = "detent"
        static let lensPress = "lens press"      // the current space's lens pressed
        static let copyLink = "copy link"        // with the "Link Copied" toast
        static let copyAnswer = "copy answer"    // the field's answer plate, "Copied" in it
        static let pageToggle = "page toggle"    // Keep, Reader, Desktop Site
        static let zoomStep = "zoom step"        // Page Zoom − +
        static let zoomReset = "zoom reset"      // back to 100 %
        static let findStep = "find step"
        static let notFound = "not found"        // nothing to find
        static let refresh = "refresh"           // pull to refresh past its threshold
        static let settingsOpen = "settings"     // the gear
        static let chatInfo = "chat info"        // the face opens Info
        static let carouselEnd = "carousel end"
        static let forget = "forget"             // × on a site permission
        // About: Yab's mark opens About (About/AboutLayer).
        static let aboutPress = "about press"    // a finger on the mark
        static let aboutBack = "about back"      // ‹ out of About
        // Where the finger decides, and places that were quiet before 2026-10-09.
        static let tabCross = "tab cross"        // a swipe on the plate passes the point it turns the tab
        static let pagerEdge = "first tab"       // the pages resist before the first tab
        static let newTabPage = "new tab page"   // past the last tab, the blank page is New Tab
        static let flickLetGo = "flick"          // a flick up on the stack is let go past its commit
        static let cardThrown = "card thrown"    // a card thrown away in All Tabs
        static let backCross = "back cross"      // a pull from the edge passes half the screen
        static let backNothing = "nothing back"  // the rubber band, nothing behind the page
        static let zoomLimit = "zoom limit"      // Page Zoom at its smallest or largest
        static let downloadReady = "download ready"   // success
        static let downloadFailed = "download failed" // error
        static let voiceHeard = "voice heard"    // what was heard goes into the field
        static let taskSent = "task sent"        // a task from the field goes to the Mac
        static let copied = "copied"             // Copy in a chat, with its "Copied"
        static let stackTap = "stack tap"        // the tab stack tapped, All Tabs on its way
        static let lookStep = "look step"        // a look's slider crosses a step (the Mac's Detents tick)
        static let lookEnd = "look end"          // a look's slider reaches 0 or 100% (the Mac's Knock)
        static let lookPick = "look pick"        // a preset, + or −, drawings picked on Color
        static let lookPage = "look page"        // the presets turn a page
        static let lookDot = "look dot"          // a handle crosses into the next dot of the field
        static let permission = "permission"     // a site's permission answered in Site Settings
        static let sheetBack = "sheet back"      // ‹ inside the page menu's sheet
        static let edited = "edited"             // a rename saved, a folder made
        static let nowDismissed = "now dismissed" // the Now line swept or crossed away
        static let unlockFailed = "unlock failed" // error: Face ID said no to Private
        static let welcomeBurst = "welcome burst" // the first run's drawings leave the drop
        static let spaceMade = "space made"
        static let spaceDeleted = "space deleted"
        static let undone = "undone"             // Clear's Undo
    }

    /// Which tone each moment is; a moment not named goes by its kind.
    static func tone(_ kind: Kind, _ reason: String) -> Tone {
        switch reason {
        case Reason.tabCross, Reason.spaceUnderLens, Reason.zoomStep, Reason.findStep,
             Reason.swipeThreshold, "swipe through", Reason.appIconPreview, Reason.reload, "back to opener", Reason.backCross,
             Reason.settingsOpen, Reason.lensPress, Reason.chatInfo, Reason.voiceHeard, "find",
             "site settings", Reason.stackTap, Reason.lookStep, Reason.lookPick, Reason.lookPage, Reason.lookDot, Reason.detent, Reason.aboutPress, Reason.aboutBack,
             Reason.permission, Reason.sheetBack, Reason.nowDismissed:
            return .tick
        case Reason.cardThrown, Reason.clear, Reason.lookEnd, Reason.privateUnlocked, Reason.welcomeBurst, "drop":
            return .thud
        case Reason.pagerEdge, Reason.backNothing, Reason.zoomLimit, Reason.carouselEnd, "icon end":
            return .wall
        case Reason.notFound, "reader none":
            return .wallTwice
        default: break
        }
        switch kind {
        case .selection: return .tick
        case .soft, .light, .medium: return .tap
        case .rigid: return .thud
        case .success: return .success
        case .warning: return .warning
        case .error: return .error
        }
    }

    /// How hard a moment's soft impact lands.
    enum Feel {
        static func intensity(_ tone: Tone) -> CGFloat {
            switch tone {
            case .tick: 0.7
            case .tap: 0.9
            case .thud: 1
            case .wall, .wallTwice: 0.55
            case .success, .warning, .error: 1
            }
        }

        static func intensity(_ kind: Kind, _ reason: String) -> CGFloat {
            intensity(tone(kind, reason))
        }
    }

    /// Plays `kind` now. `reason` names the moment, for the journal.
    @MainActor
    static func play(_ kind: Kind, reason: String) {
        Journal.shared.append(kind, reason)
        guard !Journal.shared.silent else { return }
        let tone = tone(kind, reason)
        switch tone {
        case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .tick, .tap, .thud, .wall, .wallTwice:
            impact(Feel.intensity(tone))
            if tone == .wallTwice {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.095) { impact(Feel.intensity(tone)) }
            }
        }
    }

    /// One soft generator, kept and prepared, so a tick never lags the touch.
    @MainActor private static let softGenerator = UIImpactFeedbackGenerator(style: .soft)

    @MainActor
    private static func impact(_ intensity: CGFloat) {
        softGenerator.impactOccurred(intensity: intensity)
        softGenerator.prepare()
    }

    /// Wakes the haptic engine at the start of a gesture, so its tick lands
    /// on the frame it belongs to.
    @MainActor
    static func prepare() { softGenerator.prepare() }

    /// Every haptic played since launch, in order, in test runs.
    @MainActor
    static var played: [(kind: Kind, reason: String)] { Journal.shared.entries }

    /// The journal: on when the app runs a test world (-YabWorld) or under
    /// XCTest, off for people.
    @MainActor
    final class Journal {
        static let shared = Journal()
        private(set) var entries: [(kind: Kind, reason: String)] = []
        let url: URL?
        /// No generators in tests that only want the order.
        let silent: Bool
        private let records: Bool
        private let start = Date()
        private let log = Logger(subsystem: "dev.serafim.fast.iphone", category: "haptics")

        init(environment: [String: String] = ProcessInfo.processInfo.environment, testing: Bool = LaunchOptions.current.isTestRun) {
            silent = environment["YAB_HAPTICS_SILENT"] == "1"
            records = testing || !(environment["YAB_HAPTICS_JOURNAL"] ?? "").isEmpty
            if let path = environment["YAB_HAPTICS_JOURNAL"], !path.isEmpty {
                url = URL(fileURLWithPath: path)
            } else if testing {
                url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
                    .appendingPathComponent("yab-haptics.log")
            } else {
                url = nil
            }
            if let url { try? Data().write(to: url) }
        }

        func append(_ kind: Kind, _ reason: String) {
            guard records else { return }
            entries.append((kind, reason))
            log.debug("haptic \(kind.rawValue, privacy: .public) \(reason, privacy: .public)")
            guard let url else { return }
            let line = String(format: "%.3f %@ %@\n", Date().timeIntervalSince(start), kind.rawValue, reason)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
