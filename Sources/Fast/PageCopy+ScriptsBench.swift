import AppKit

extension PageCopy {
    /// Observe an accepted native action without sending another key or
    /// manufacturing an offer. Ordinary app runs never expose the clipboard.
    var scriptsBenchState: [String: Any] {
        guard Store.testing else { return [:] }
        let shown: String
        switch stage {
        case nil: shown = "none"
        case .offering: shown = "offering"
        case .done(let pick): shown = "done:\(pick)"
        }
        return ["stage": shown, "words": words, "canSave": canSave,
                "clipboard": Self.board.string(forType: .string) ?? ""]
    }
}
