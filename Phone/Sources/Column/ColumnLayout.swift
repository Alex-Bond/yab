import CoreGraphics
import Foundation

/// What the column's pages were laid out from; the spaces (Field/NewTabSpaces)
/// keep its name for which list a held tab belongs to.
enum ColumnLayout {
    /// Which list a tab row belongs to.
    enum List: Hashable {
        case pins
        case kept
        case folder(Folder.ID)
        case today
    }
}

/// Pins across the whole width: at most five a row, rows as even as they can
/// be, at most three rows until the person asks for all (the 15th cell then
/// says "+N more").
struct PinGrid: Equatable {
    struct Cell: Equatable, Identifiable {
        enum Kind: Equatable {
            case pin(Tab)
            case more(Int)
        }
        let kind: Kind
        let frame: CGRect
        var id: String {
            switch kind {
            case let .pin(tab): tab.id
            case .more: "more"
            }
        }
    }

    let cells: [Cell]
    let columns: Int
    let rows: Int
    let height: CGFloat

    init(pins: [Tab], open: Bool, width: CGFloat) {
        typealias C = Metrics.Column
        let shown = C.pinsPerRow * C.pinRowsMax
        let count = pins.count > shown && !open ? shown : pins.count
        guard count > 0 else {
            cells = []
            columns = 0
            rows = 0
            height = 0
            return
        }
        let rows = (count + C.pinsPerRow - 1) / C.pinsPerRow
        let columns = (count + rows - 1) / rows
        let w = (width - CGFloat(columns - 1) * C.pinGap) / CGFloat(columns)
        var cells: [Cell] = []
        for i in 0..<count {
            let frame = CGRect(x: CGFloat(i % columns) * (w + C.pinGap), y: CGFloat(i / columns) * (C.pinHeight + C.pinGap),
                               width: w, height: C.pinHeight)
            if count < pins.count && i == count - 1 {
                cells.append(Cell(kind: .more(pins.count - (count - 1)), frame: frame))
            } else {
                cells.append(Cell(kind: .pin(pins[i]), frame: frame))
            }
        }
        self.cells = cells
        self.columns = columns
        self.rows = rows
        height = CGFloat(rows) * C.pinHeight + CGFloat(rows - 1) * C.pinGap
    }
}
