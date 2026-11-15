import AppKit

/// Widths of the two kinds of tabs in the strip. `fixed` includes open
/// folders whose pills hug their names, pins, and the divider and gaps.
struct StripWidths: Equatable {
    static let moreWidth: CGFloat = 72
    let outer: CGFloat
    let inner: CGFloat
    let activeInner: CGFloat
    let activeOuter: CGFloat
    let content: CGFloat

    /// An open folder's pill: as wide as its name, in the weight the pill
    /// draws it in (NestPill, FolderPill). Measured in a lighter one, the
    /// name came out a point or two longer than its room, and its last
    /// letter was cut by the fade (feedback #91). Past a tab's width it
    /// fades out at the end, as a tab's title does.
    static func pillWidth(_ name: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let title = (name as NSString).size(withAttributes: [.font: font]).width
        // 11 + 15 mark + 6 gap + name + 7, and a point for a glyph that
        // paints past its advance (a closing "e", "f" or "y").
        return min(Metrics.tabWidth, max(48, ceil(39 + title + 1)))
    }

    static func solve(room: CGFloat, outer: Int, inner: Int, fixed: CGFloat,
                      activeInside: Bool = false, activeOutside: Bool = false) -> StripWidths {
        let outerCount = CGFloat(max(0, outer))
        let innerCount = CGFloat(max(0, inner))
        let active = activeInside && inner > 0 ? CGFloat(1) : 0
        let activeOut = activeOutside && outer > 0 ? CGFloat(1) : 0
        let ordinaryInner = innerCount - active
        let ordinaryOuter = outerCount - activeOut
        let full = Metrics.tabWidth
        let titled = Metrics.tabTitled
        let minimum = Metrics.tabMinWidth
        var outside = full
        var inside = full
        var activeWidth = full
        var activeOuterWidth = full
        var shortage = max(0, fixed + (outerCount + innerCount) * full - room)

        func take(_ capacity: CGFloat) -> CGFloat {
            let used = min(shortage, capacity)
            shortage -= used
            return used
        }

        // The folder gives up its spare width before the rest of the row.
        if innerCount > 0 {
            let used = take(innerCount * (full - titled))
            inside -= used / innerCount
            activeWidth = inside
        }
        if outerCount > 0 {
            outside -= take(outerCount * (full - titled)) / outerCount
            activeOuterWidth = outside
        }
        // Once titles cannot all fit, preserve the active folder tab's name.
        if ordinaryInner > 0 { inside -= take(ordinaryInner * (titled - minimum)) / ordinaryInner }
        if ordinaryOuter > 0 { outside -= take(ordinaryOuter * (titled - minimum)) / ordinaryOuter }
        let content = fixed + ordinaryOuter * outside + activeOut * activeOuterWidth
            + ordinaryInner * inside + active * activeWidth
        return StripWidths(outer: outside, inner: inside, activeInner: activeWidth,
                           activeOuter: activeOuterWidth, content: content)
    }
}
