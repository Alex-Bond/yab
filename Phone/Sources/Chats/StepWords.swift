import Foundation
#if canImport(SyncKit)
import SyncKit
#endif

// A step of an agent's work in words: the table is SyncKit's (StepWords),
// the Mac's too, so a step never reads one way there and another here. A
// step names a tab by the Mac's own id ("tab:<id>"), which means nothing on
// this iPhone: it is said without it. Keys pressed are said by their names.

extension StepWords {
    static func of(_ step: TurnWork.Step) -> StepWords { of(kind: step.kind, name: step.name, detail: step.detail, text: step.text) }

    /// A tool call, by its name and what it was about.
    static func tool(_ name: String, detail: String, outcome: String = "") -> StepWords {
        tool(name, detail: detail, outcome: outcome, place: nil)
    }

    /// The hosts a detail names: one, or several joined by commas.
    static func hosts(_ detail: String) -> [String] { hosts(detail, place: nil) }
}
