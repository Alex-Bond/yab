import SwiftUI

/// A Mac folder's actual custom drawing, image or emoji, at every depth.
/// Newer or unavailable marks keep the grid, never display their storage key.
struct FolderMark: View {
    let mark: String?
    let open: Bool
    let tint: RGB
    let dark: Bool
    var size: CGFloat = Metrics.Column.folderIcon
    var artwork: SyncFolderArtwork? = nil
    var isPrivate = false
    /// The color given this folder on the Mac; it takes over from `tint`.
    var color: String? = nil

    var body: some View {
        Group {
            if let mark, mark.hasPrefix("icon:"), let image = MacIconMarks.image(String(mark.dropFirst(5))) {
                Image(uiImage: image).resizable().renderingMode(.template).scaledToFit().foregroundStyle(Ink.primary)
            } else if let mark, let image = artwork?.image(mark, isPrivate: isPrivate) {
                Image(uiImage: image).resizable().renderingMode(.original).scaledToFit()
            } else if let mark, !mark.isEmpty, !mark.contains(":") {
                Text(mark).font(.system(size: size))
            } else {
                // As in the Mac's column: the outline as wide as a site's icon
                // beside it, its line 2/24 of that (SideBar.folder, folderWeight).
                FolderIcon(open: open, size: size * 24 / 18, base: FolderColor.rgb(color) ?? tint, dark: dark, weight: 2 * size / 24)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The colors a folder can be given (FolderTint in Sources/Fast/Kept.swift).
/// Black is No Color: the folder wears its space's shades.
enum FolderColor {
    static func rgb(_ stored: String?) -> RGB? {
        switch stored {
        case "teal": RGB(0x11, 0xAF, 0x91)
        case "blue": RGB(0x11, 0x9A, 0xD0)
        case "purple": RGB(0x75, 0x66, 0xAF)
        case "yellow": RGB(0xEA, 0xB5, 0x1B)
        case "pink": RGB(0xDE, 0x76, 0x98)
        case "red": RGB(0xCC, 0x51, 0x62)
        case "orange": RGB(0xE4, 0x7B, 0x4D)
        default: nil
        }
    }
}

extension Space {
    /// The color a folder's shades are worked out on: the one the Mac's
    /// column wears for this space, light or deepened, not the wash or the
    /// dimmed page behind the row, so a folder is the same on both.
    func folderGround(dark: Bool) -> RGB {
        if let color = look?.displayColors(dark: dark).first { return color }
        guard !isPrivate else { return tint }
        func unwash(_ c: Int) -> Int { min(255, max(0, Int(((Double(c) - 255 * 0.82) / 0.18).rounded()))) }
        let picked = RGB(unwash(tint.r), unwash(tint.g), unwash(tint.b))
        return dark ? LookColor.deepened(picked) : picked
    }
}
