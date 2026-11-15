import SwiftUI
import UIKit

/// Where the capsule of spaces stands this frame (CapsuleModel's springs),
/// in the screen's points: what the spaces' card draws (NewTabSpaces).
struct CapsulePose: Equatable {
    /// The capsule: its left edge and width.
    var left: CGFloat
    var width: CGFloat
    /// The first name's left edge.
    var trackX: CGFloat
    /// The lens: its middle and width (the name + 16).
    var lensCenter: CGFloat
    var lensWidth: CGFloat
    /// The lens's place on the names: 1.4 is 40% of the way from the second to the third.
    var f: CGFloat
    /// The side buttons stepping out: 0 in place, 1 gone 70 aside.
    var side: CGFloat
    /// The lens pressed: 0 to 1, scaling it 1 to 1.08.
    var press: CGFloat
    /// Names run past that edge: it fades over 18.
    var fadeLeft: Bool
    var fadeRight: Bool

    var right: CGFloat { left + width }

    /// At rest between the buttons of a bar `barWidth` wide, centered on `mid`.
    static func rest(mid: CGFloat, barWidth: CGFloat = Metrics.Column.barWidth) -> CapsulePose {
        let width = barWidth - Metrics.Column.capsuleInset * 2
        return CapsulePose(left: mid - width / 2, width: width, trackX: mid - width / 2, lensCenter: mid, lensWidth: 0,
                           f: 0, side: 0, press: 0, fadeLeft: false, fadeRight: false)
    }

    init(left: CGFloat, width: CGFloat, trackX: CGFloat, lensCenter: CGFloat, lensWidth: CGFloat,
         f: CGFloat, side: CGFloat, press: CGFloat, fadeLeft: Bool, fadeRight: Bool) {
        self.left = left; self.width = width; self.trackX = trackX
        self.lensCenter = lensCenter; self.lensWidth = lensWidth
        self.f = f; self.side = side; self.press = press
        self.fadeLeft = fadeLeft; self.fadeRight = fadeRight
    }

    init(_ model: CapsuleModel) {
        let lens = model.lens
        let fades = model.fades
        self.init(left: model.capLeft, width: model.capW.v, trackX: model.trackX.v,
                  lensCenter: lens.center, lensWidth: lens.width, f: model.f.v,
                  side: ColumnMath.clamp(model.side.v, 0, 1), press: max(0, model.press.v),
                  fadeLeft: fades.left, fadeRight: fades.right)
    }
}

/// The recess the names sit in: darker than the sheet, a soft shadow inside
/// its top and a light hairline along its bottom.
struct CapsuleRecess: View {
    let dark: Bool

    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.black.opacity(dark ? 0.32 : 0.075)
                .shadow(.inner(color: .black.opacity(dark ? 0.55 : 0.17), radius: 1.5, y: 1.5))
                .shadow(.inner(color: .white.opacity(dark ? 0.07 : 0.45), radius: 0, y: -1)))
            .allowsHitTesting(false)
    }
}

/// The lens, a rounded rect anywhere inside its view: the glass is drawn in
/// it while the content keeps the whole frame.
struct LensShape: Shape {
    var rect: CGRect
    var radius: CGFloat
    var scale: CGFloat = 1

    func path(in bounds: CGRect) -> Path {
        let r = rect.insetBy(dx: -rect.width * (scale - 1) / 2, dy: -rect.height * (scale - 1) / 2)
        return Path(roundedRect: r, cornerRadius: min(radius * scale, r.height / 2), style: .continuous)
    }
}

/// The capsule's names laid end to end: each 14 + its words + 14; where the
/// lens stands for a position between two spaces.
struct CapsuleTrack: Equatable {
    let widths: [CGFloat]
    let centers: [CGFloat]

    init(names: [String]) {
        typealias C = Metrics.Column
        let font = UIFont.systemFont(ofSize: C.nameInCapsuleFont, weight: .semibold)
        let widths = names.map { name -> CGFloat in
            let text = NSAttributedString(string: name, attributes: [.font: font, .kern: C.nameTracking * C.nameInCapsuleFont])
            return ceil(text.size().width * 10) / 10 + C.nameInCapsulePadding * 2
        }
        self.init(widths: widths)
    }

    init(widths: [CGFloat]) {
        var x: CGFloat = 0
        var centers: [CGFloat] = []
        for w in widths {
            centers.append(x + w / 2)
            x += w
        }
        self.widths = widths
        self.centers = centers
    }

    /// The lens's middle on the track and the name's width under it.
    func at(_ f: CGFloat) -> (center: CGFloat, width: CGFloat) {
        guard !widths.isEmpty else { return (0, 0) }
        let i = min(max(Int(f.rounded(.down)), 0), widths.count - 1)
        let j = min(i + 1, widths.count - 1)
        let t = f - CGFloat(i)
        return (ColumnMath.lerp(centers[i], centers[j], t), ColumnMath.lerp(widths[i], widths[j], t))
    }
}
