import Foundation

/// Which pages can be shown by this turn, and whether they can keep the
/// current plate still. Pure so unknown rows cannot become setup work in
/// a diagnostic. A swipe has only real neighbors; a key crosses the range.
enum SpacePlateRouting {
    struct Plate: Equatable {
        let shown: Bool
        let extensionHeight: CGFloat
        let extensions: [String]

        init(shown: Bool, extensionHeight: CGFloat = 0, extensions: [String] = []) {
            self.shown = shown
            self.extensionHeight = shown ? extensionHeight : 0
            self.extensions = shown ? extensions : []
        }
    }

    static func places(home: Int, count: Int, toward target: Int?) -> [Int] {
        guard count > 0, (0..<count).contains(home) else { return [] }
        if let target {
            guard (0..<count).contains(target) else { return [] }
            return (min(home, target)...max(home, target)).filter { $0 != home }
        }
        return [home - 1, home + 1].filter { (0..<count).contains($0) }
    }

    /// A known difference needs a pictured plate even if another row is
    /// unknown. Otherwise an unknown remains unknown until normal setup.
    static func moves(from current: Bool, to plates: [Bool?]) -> Bool? {
        if plates.compactMap({ $0 }).contains(where: { $0 != current }) { return true }
        return plates.contains(where: { $0 == nil }) ? nil : false
    }

    static func moves(from current: Plate, to plates: [Plate?]) -> Bool? {
        if plates.compactMap({ $0 }).contains(where: { $0 != current }) { return true }
        return plates.contains(where: { $0 == nil }) ? nil : false
    }
}
