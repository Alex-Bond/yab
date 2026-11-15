import Foundation
import SwiftUI
import os

/// The motions of a task's screens that Motion doesn't name yet, the
/// prototype's numbers, and a journal of every motion the tasks run.
extension Motion {
    /// The Face ID panel: in over 0.2 s, its box from .9 with the system's
    /// small give (cubic-bezier(.3, 1.4, .4, 1), 0.3 s); out in 0.2 s.
    static let faceIDIn = curve("faceIDIn", 0.3, 1.4, 0.4, 1, 0.3)
    static let faceIDOut = linear("faceIDOut", 0.2)
    /// Looking: the glyph pulses, 0.7 s each way (CSS ease-in-out, alternate).
    static let faceIDPulse = curve("faceIDPulse", 0.42, 0, 0.58, 1, 0.7)
    /// The live step's dot beats, a second each way (CSS ease-in-out, alternate).
    static let stepBeat = curve("stepBeat", 0.42, 0, 0.58, 1, 1)
    /// Signed: the glyph turns green at once.
    static let faceIDSigned = linear("faceIDSigned", 0.12)
    /// The Island and the Lock Screen in the pictures (the system's own on iOS).
    static let lockIn = curve("lockIn", 0.3, 0.8, 0.2, 1, 0.45)
}

/// Every motion the tasks ran, by name, in test runs: written one line each
/// to the file named by YAB_MOTION_JOURNAL (UI tests read it back), as the
/// haptics journal is. The motions themselves run inside their signposts
/// (Motion.run); this only says which ran, in what order.
@MainActor
enum TaskMotion {
    /// Full test histories are retained; ordinary users do not build a ledger.
    static var played: [String] { Journal.shared.entries }

    /// Runs `motion` over `body`, as Motion.run does, and notes it.
    static func run(_ motion: Motion, _ body: () -> Void, completion: (@MainActor () -> Void)? = nil) {
        note(motion)
        motion.run(body, completion: completion)
    }

    static func note(_ motion: Motion) { Journal.shared.append(motion) }

    /// An owned journal is injectable without resetting the shared test history.
    @MainActor
    final class Journal {
        static let shared = Journal()
        private(set) var entries: [String] = []
        let url: URL?
        private let records: Bool
        private let start = Date()

        init(environment: [String: String] = ProcessInfo.processInfo.environment,
             testing: Bool = LaunchOptions.current.isTestRun) {
            if let path = environment["YAB_MOTION_JOURNAL"], !path.isEmpty {
                url = URL(fileURLWithPath: path)
            } else { url = nil }
            records = testing || url != nil
            if let url { try? Data().write(to: url) }
        }

        func append(_ motion: Motion) {
            guard records else { return }
            let name = "\(motion.name)"
            entries.append(name)
            guard let url else { return }
            let line = String(format: "%.3f %@\n", Date().timeIntervalSince(start), name)
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
