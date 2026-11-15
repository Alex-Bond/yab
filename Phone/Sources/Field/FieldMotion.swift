import SwiftUI

/// The field's movements beyond the skeleton's (Design/Motion.swift),
/// with the prototype's numbers (motion.md): what fades with the field's
/// grow and land, the plate's menu going, the eyes' pupils. Each runs inside its own signpost, as every Motion does.
extension Motion {
    /// The frosted backdrop comes in linearly as the field grows (200 ms) and
    /// goes a little quicker (180 ms).
    static let fieldBackdrop = linear("fieldBackdrop", 0.2)
    static let fieldBackdropOut = linear("fieldBackdropOut", 0.18)
    /// The field following the keyboard when it says it is taller or shorter.
    static let keyboardFollow = easeOut("keyboardFollow", 0.3)
    /// The field's own contents fade as it lands back on the plate.
    static let fieldContentsOut = linear("fieldContentsOut", 0.12)
    /// The plate's menu going: quicker than it came.
    static let plateMenuClose = easeIn("plateMenuClose", 0.15)
    /// The pupils go as the lids come down (.1 s).
    static let eyesPupils = linear("eyesPupils", 0.1)
}

extension Motion {
    /// Reduce Motion's stand-in for a morph (a shape growing out of a button,
    /// a card folding into the plate or the Now line): the same change as a
    /// 0.2 s cross-fade (PLAN-iphone.md §7).
    static let crossFade = curve("crossFade", 0.42, 0, 0.58, 1, 0.2)
}

/// Reduce Motion for the field's, the menu's morphs, and the
/// journal tests read to see a cross-fade ran in a morph's place.
@MainActor
enum FieldMotion {
    /// The system's Reduce Motion, or `-YabReduceMotion YES` for tests.
    static var reduced: Bool { forced || Motion.reduced }

    /// Reduce Motion asked for by the launch (tests set it too).
    static var forced: Bool = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let i = arguments.firstIndex(of: "-YabReduceMotion"), i + 1 < arguments.count else { return false }
        return ["yes", "true", "1"].contains(arguments[i + 1].lowercased())
    }()

    /// The last morphs and cross-fades, newest last, for unit tests.
    static var lately: [String] = []

    /// A morph, or with Reduce Motion the cross-fade's change in its place.
    static func morph(_ motion: Motion, _ body: () -> Void, fade: () -> Void, completion: (@MainActor () -> Void)? = nil) {
        if reduced {
            note(Motion.crossFade, instead: motion)
            Motion.crossFade.run(fade, completion: completion)
        } else {
            note(motion)
            motion.run(body, completion: completion)
        }
    }

    /// Test runs: one line per morph or cross-fade, "<name>" or
    /// "crossFade <morph>", to the file YAB_MOTION_JOURNAL names.
    static func note(_ motion: Motion, instead morph: Motion? = nil) {
        let entry = "\(motion.name)" + (morph.map { " \($0.name)" } ?? "")
        #if DEBUG
        lately = Array((lately + [entry]).suffix(50))
        #endif
        guard let url = journal else { return }
        let line = entry + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private static let journal: URL? = {
        guard let path = ProcessInfo.processInfo.environment["YAB_MOTION_JOURNAL"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }()
}
