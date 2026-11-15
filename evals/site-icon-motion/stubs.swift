import SwiftUI

// Just enough of Yab for SiteControlsIcon.swift to compile on its own.
enum Palette {
    static let ground = Color(white: 0.1)
    static let ink = Color(white: 0.92)
    static let muted = Color(white: 0.65)
    static let wash = Color(white: 1).opacity(0.07)
}
enum Glyphs { static let scale: CGFloat = 1.35 }
struct Symbol: View {
    let name: String
    init(_ name: String, size: CGFloat, weight: Font.Weight) { self.name = name }
    var body: some View { Image(systemName: name) }
}
