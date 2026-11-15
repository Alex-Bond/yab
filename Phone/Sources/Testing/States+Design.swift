import Foundation

/// The skeleton's own check, not a prototype frame: every drawing of the
/// design layer on one screen (DesignSheet).
extension StateCatalog {
    static let design: [NamedState] = [
        NamedState("design.1", "Design", "Folders, favicons, glyphs and glass, to compare with the prototype's.") { app in
            app.showsDesignSheet = true
        },
    ]
}
