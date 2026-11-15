import Foundation
import Testing
@testable import Fast

@MainActor
struct SideExtensionLayoutTests {
    private func layout(width: CGFloat, count: Int, door: CGFloat) -> SideExtensionLayout {
        SideExtensionLayout(width: width, count: count, door: door, margin: SideBar.margin,
                            columns: SideBar.pinColumns(count, width: width), gap: SideBar.pinGap)
    }

    @Test func emptyAndSinglePinKeepAddressHeight() {
        for count in [0, 1] {
            let layout = layout(width: 240, count: count, door: 28)
            #expect(!layout.separate)
            #expect(layout.height == 0)
        }
    }

    @Test func wideningTheSidebarBringsTheSamePinsBackInline() {
        let narrow = layout(width: 240, count: 4, door: 28)
        let wide = layout(width: 360, count: 4, door: 28)
        #expect(narrow.separate)
        #expect(narrow.columns == 4)
        #expect(narrow.cell >= 28)
        #expect(!wide.separate)
        #expect(wide.height == 0)
    }

    @Test func everyPinHasRoomAtEveryDensity() {
        for door: CGFloat in [26, 28] {
            for width: CGFloat in [200, 240, 300, 360] {
                for count in [4, 8, 12, 30] {
                    let layout = self.layout(width: width, count: count, door: door)
                    if layout.separate {
                        #expect(layout.cell >= door)
                        #expect(CGFloat(layout.columns) * layout.cell + CGFloat(layout.columns - 1) * layout.gap <= width - 16 + 0.01)
                        let rows = Int(layout.height / (door + layout.gap))
                        #expect(rows * layout.columns >= count)
                    }
                }
            }
        }
    }
    @Test func extensionTilesUseTheFavoritesGrid() {
        for width: CGFloat in [200, 220, 240, 300, 360] {
            for count in [4, 5, 6, 12] {
                let extensions = layout(width: width, count: count, door: 28)
                let favorites = ColumnLayout.grid(count: count, width: width)
                #expect(extensions.columns == favorites.cols)
                #expect(abs(extensions.cell - favorites.width) < 0.01)
                #expect(extensions.gap == SideBar.pinGap)
            }
        }
    }

}
