import SwiftUI

/// Every drawing of the design layer on one screen, for checking them
/// against the prototype's: folders in each space's shades, shut and open,
/// favicons, the glyphs, Yab's mark and the agent's face, and the glass
/// plates over a light and a dark ground. Named state design.1; not a
/// prototype frame, the skeleton's own check.
struct DesignSheet: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Design").font(.system(size: 28, weight: .bold))
                folders
                favicons
                glyphs
                glass
            }
            .padding(.horizontal, Metrics.Edge.content)
            .padding(.top, Metrics.statusBar + 6)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.white)
        .accessibilityIdentifier("design.sheet")
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.tertiary).textCase(.uppercase)
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Folders: each space, shut and open, 22 and 44")
            ForEach(app.browser.spaces) { space in
                HStack(spacing: 14) {
                    Text(space.emoji).font(.system(size: 18))
                    FolderIcon(open: false, size: 22, base: space.tint)
                    FolderIcon(open: true, size: 22, base: space.tint)
                    FolderIcon(open: false, size: 44, base: space.tint)
                    FolderIcon(open: true, size: 44, base: space.tint)
                    FolderIcon(open: false, size: 44, base: space.tint, dark: true)
                        .background(Color(red: 0.14, green: 0.13, blue: 0.17), in: RoundedRectangle(cornerRadius: 8))
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color(rgb: space.tint), in: RoundedRectangle(cornerRadius: Metrics.Radius.row))
            }
        }
    }

    private var favicons: some View {
        let keys = Array(Set(app.browser.allTabs.map(\.icon) + ["tap", "paul", "nng", "orbit", "rams", "face", "unknown"])).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            caption("Favicons: 20, 24")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 7), alignment: .leading, spacing: 8) {
                ForEach(keys, id: \.self) { key in
                    VStack(spacing: 3) {
                        HStack(spacing: 2) {
                            Favicon(icon: key, size: 20)
                            Favicon(icon: key, size: 24)
                        }
                        Text(key).font(.system(size: 8)).foregroundStyle(Ink.tertiary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var glyphs: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Glyphs: 20")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 10), alignment: .leading, spacing: 8) {
                ForEach(GlyphName.allCases, id: \.self) { name in
                    Glyph(name, size: 20)
                }
                YabMark(size: 20)
                AgentFace(size: 20)
            }
        }
    }

    private var glass: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("Glass: light, tinted, dark, private")
            ForEach([false, true], id: \.self) { darkGround in
                ZStack {
                    LinearGradient(colors: darkGround ? [.black, Color(white: 0.2)] : [Color(white: 0.95), Color(red: 1, green: 0.85, blue: 0.7)],
                                   startPoint: .leading, endPoint: .trailing)
                    HStack(spacing: 8) {
                        Glyph(.chevronLeft, size: 22).frame(width: 50, height: 50).glassCircle(tone: .light)
                        Text("Work").font(.system(size: 16, weight: .semibold)).frame(width: 90, height: 50)
                            .glassCapsule(tone: .tinted(RGB(226, 233, 244)))
                        Text("Dark").font(.system(size: 16, weight: .semibold)).frame(width: 70, height: 50).glassCapsule(tone: .dark)
                        Glyph(.incognito, size: 22, color: .white).frame(width: 50, height: 50).glassCircle(tone: .privateTab)
                    }
                }
                .frame(height: 74)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.row))
            }
        }
    }
}
