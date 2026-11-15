import SwiftUI

/// Site Settings, the page menu's sheet with another body (SCENE 14, the
/// Mac's Site Controls): this site's zoom and desktop mode, what it was
/// allowed (only what it asked for), the connection, clearing its data, and
/// Yab Settings at the foot. Row glyphs are white on colored rounded
/// squares, as iOS Settings has them.
struct SiteSettingsBody: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    let ink: PageMenuInk
    private typealias S = Metrics.SiteSettingsPage

    var body: some View {
        let host = app.siteHost(of: tab)
        let isPrivate = app.pageIsPrivate
        let zoom = app.pageZoom
        let desktop = app.pageIsDesktop
        let permissions = app.siteSettings.permissions(host, isPrivate: isPrivate)
        let connection = app.pages.connection(tab.id, fallback: tab.navigationURL)
        // Private files are never remembered here.
        let downloaded = isPrivate ? 0 : app.downloads.list(isPrivate: false, host: host).count
        VStack(alignment: .leading, spacing: 0) {
            // The header already names the site: no caption over its first card.
            card {
                row(.textSize, tile: .blue, "Page Zoom", id: "site.zoom") {
                    ZoomStepper(zoom: zoom, ink: ink, idPrefix: "site.zoom", compact: true) { app.pageMenuZoom($0) }
                }
                divider
                row(.window, tile: .teal, "Request Desktop Site", id: "site.desktop") {
                    Toggle("Request Desktop Site", isOn: Binding(get: { desktop }, set: { _ in app.pageMenuDesktop() }))
                        .labelsHidden()
                        .accessibilityIdentifier("site.desktop.toggle")
                }
                // The blocker, while it is on and working (the Mac's site
                // card): off here, this site loads everything again.
                if SettingsStore.shared.blocksAds, app.pages.shield?.trouble == nil {
                    divider
                    row(.shieldCheck, tile: .green, "Block Ads and Trackers", id: "site.blocksAds") {
                        Toggle("Block Ads and Trackers", isOn: Binding(get: { app.pageBlocksAds }, set: { app.pageMenuBlocksAds($0) }))
                            .labelsHidden()
                            .accessibilityIdentifier("site.blocksAds.toggle")
                    }
                }
            }

            if !permissions.isEmpty {
                caption("Allowed Here").padding(.top, S.sectionGap)
                card {
                    ForEach(Array(permissions.enumerated()), id: \.element.0) { i, entry in
                        if i > 0 { divider }
                        permissionRow(entry.0, entry.1)
                    }
                }
            }

            if downloaded > 0 {
                card {
                    Button { app.openSiteDownloads() } label: {
                        rowLabel(SiteGlyph(mac: .doc, tile: .blue), "Downloaded Here") {
                            HStack(spacing: 4) {
                                Text("\(downloaded)")
                                    .font(.system(size: S.rowFont))
                                    .foregroundStyle(ink.secondary)
                                chevron
                            }
                        }
                    }
                    .buttonStyle(PageMenuPress(ink: ink, radius: S.cardRadius) { app.prepare(.downloads, $0) })
                    .accessibilityIdentifier("site.downloaded")
                }
                .padding(.top, permissions.isEmpty ? S.sectionGap : S.cardGap)
            }

            card {
                if connection.secure {
                    Button { app.openCertificate() } label: {
                        rowLabel(.lock, tile: .green, "Connection is secure") { chevron }
                    }
                    .buttonStyle(PageMenuPress(ink: ink, radius: S.cardRadius) { app.prepare(.certificate, $0) })
                    .accessibilityIdentifier("site.connection")
                } else {
                    rowLabel(.lock, tile: .red, "Not secure", red: true) { EmptyView() }
                        .accessibilityIdentifier("site.connection")
                }
            }
            .padding(.top, permissions.isEmpty && downloaded == 0 ? S.sectionGap : S.cardGap)

            card {
                Button { app.pageMenu.confirmClear = true } label: {
                    rowLabel(.trashCan, tile: .red, "Clear Data for This Site…", red: true) { EmptyView() }
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: S.cardRadius))
                .accessibilityIdentifier("site.clear")
            }
            .padding(.top, S.cardGap)

            card {
                Button { app.pageMenuYabSettings() } label: {
                    rowLabel(.settingsGear1, tile: .gray, "Yab Settings") { chevron }
                }
                .buttonStyle(PageMenuPress(ink: ink, radius: S.cardRadius))
                .accessibilityIdentifier("site.yabSettings")
            }
            .padding(.top, S.cardGap)
            .padding(.bottom, Metrics.PageMenu.bottomPad)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("site.settings")
    }

    private func permissionRow(_ kind: SiteSettings.Permission, _ decision: SiteSettings.Decision) -> some View {
        row(SiteGlyph(permission: kind), kind.title, id: "site.permission.\(kind.rawValue)") {
            HStack(spacing: 4) {
                Menu {
                    ForEach(SiteSettings.Decision.allCases, id: \.self) { choice in
                        Button(choice.word) { app.setPermission(kind, choice) }
                    }
                } label: {
                    Text(decision.word)
                        .font(.system(size: S.rowFont))
                        .foregroundStyle(ink.secondary)
                        .frame(minHeight: Metrics.touch)
                }
                .accessibilityIdentifier("site.permission.\(kind.rawValue).decision")
                Button { app.forgetPermission(kind) } label: {
                    Glyph(.crossSmall, size: 14, color: ink.secondary)
                        .opacity(0.8)
                        .frame(width: 32, height: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("site.permission.\(kind.rawValue).forget")
                .accessibilityLabel("Forget \(kind.title)")
                .accessibilityHint("The site asks again next time")
            }
        }
    }

    // MARK: - parts

    private func caption(_ words: String) -> some View {
        Text(words.uppercased())
            .font(.system(size: S.captionFont))
            .tracking(0.3)
            .foregroundStyle(ink.secondary)
            .padding(.leading, S.captionX)
            .frame(height: S.captionHeight, alignment: .top)
            .accessibilityAddTraits(.isHeader)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(ink.siteCard, in: RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .padding(.horizontal, Metrics.PageMenu.inset)
    }

    private var divider: some View {
        Rectangle().fill(ink.hairline).frame(height: 0.5).padding(.leading, S.textX)
    }

    private var chevron: some View {
        Glyph(.chevronRight, size: 16, color: ink.secondary)
    }

    private func row<Trailing: View>(_ glyph: GlyphName, tile: SiteGlyph.Tile, _ title: String, id: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        row(SiteGlyph(glyph: glyph, tile: tile), title, id: id, trailing: trailing)
    }

    private func row<Trailing: View>(_ mark: SiteGlyph, _ title: String, id: String,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        rowLabel(mark, title, trailing: trailing)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(id)
    }

    private func rowLabel<Trailing: View>(_ glyph: GlyphName, tile: SiteGlyph.Tile, _ title: String, red: Bool = false,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        rowLabel(SiteGlyph(glyph: glyph, tile: tile), title, red: red, trailing: trailing)
    }

    private func rowLabel<Trailing: View>(_ mark: SiteGlyph, _ title: String, red: Bool = false,
                                          @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 0) {
            mark
                .padding(.leading, S.glyphX)
            Text(title)
                .font(.system(size: S.rowFont))
                .foregroundStyle(red ? ink.red : ink.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, S.textX - S.glyphX - S.circle)
            Spacer(minLength: 8)
            trailing()
                .padding(.trailing, S.trailing)
        }
        .frame(minHeight: S.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A row's glyph as iOS Settings draws it: white on
/// a 30-point rounded square of a system color, the same in light and dark.
/// What the thing is set to lives in the row's toggle or word, not here.
struct SiteGlyph: View {
    enum Tile {
        case blue, teal, green, orange, red, gray

        var color: Color {
            switch self {
            case .blue: Color(uiColor: .systemBlue)
            case .teal: Color(uiColor: .systemTeal)
            case .green: Color(uiColor: .systemGreen)
            case .orange: Color(uiColor: .systemOrange)
            case .red: Color(uiColor: .systemRed)
            case .gray: Color(uiColor: .systemGray)
            }
        }
    }

    var glyph: GlyphName? = nil
    /// The Mac's drawing, where the prototype has none.
    var mac: MacGlyph? = nil
    let tile: Tile
    private typealias S = Metrics.SiteSettingsPage

    init(glyph: GlyphName, tile: Tile) { self.glyph = glyph; self.tile = tile }
    init(mac: MacGlyph, tile: Tile) { self.mac = mac; self.tile = tile }
    init(permission kind: SiteSettings.Permission) { glyph = kind.glyph; mac = kind.macGlyph; tile = kind.tile }

    var body: some View {
        RoundedRectangle(cornerRadius: S.tileRadius, style: .continuous)
            .fill(tile.color)
            .overlay {
                if let mac { Glyph(mac: mac, size: S.glyph, color: .white) }
                else if let glyph { Glyph(glyph, size: S.glyph, color: .white) }
            }
            .frame(width: S.circle, height: S.circle)
            .accessibilityHidden(true)
    }
}

extension SiteSettings.Permission {
    /// iOS Settings' colors: Camera green, Microphone orange.
    var tile: SiteGlyph.Tile {
        switch self {
        case .camera: .green
        case .microphone: .orange
        case .downloads: .blue
        }
    }
}

/// The connection's own page: who the certificate names, who vouches for
/// it, until when. iOS checked it before the page opened.
struct CertificateBody: View {
    @Environment(AppModel.self) private var app
    let tab: Tab
    let ink: PageMenuInk
    private typealias S = Metrics.SiteSettingsPage

    var body: some View {
        let connection = app.pages.connection(tab.id, fallback: tab.navigationURL)
        let host = app.siteHost(of: tab)
        VStack(alignment: .leading, spacing: 0) {
            Text("The connection to \(host) is encrypted, and its certificate is valid.")
                .font(.system(size: 15))
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, S.captionX)
                .padding(.bottom, 14)
            VStack(spacing: 0) {
                fact("Issued to", connection.subject ?? host)
                if let issuer = connection.issuer {
                    Rectangle().fill(ink.hairline).frame(height: 0.5).padding(.leading, 16)
                    fact("Issued by", issuer)
                }
                if let expires = connection.expires {
                    Rectangle().fill(ink.hairline).frame(height: 0.5).padding(.leading, 16)
                    fact("Valid until", expires.formatted(date: .abbreviated, time: .omitted))
                }
            }
            .background(ink.siteCard, in: RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous))
            .padding(.horizontal, Metrics.PageMenu.inset)
            .padding(.bottom, Metrics.PageMenu.bottomPad)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("site.certificate")
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.system(size: S.rowFont)).foregroundStyle(ink.ink)
            Spacer(minLength: 12)
            Text(value).font(.system(size: S.rowFont)).foregroundStyle(ink.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: S.row)
        .accessibilityElement(children: .combine)
    }
}

extension Metrics {
    /// Site Settings' body (SCENE 14): captions at 24, cards 12 from the
    /// sheet's sides, rows 52, the glyph's tile 28 at 16, words at 54: the page menu's edges.
    enum SiteSettingsPage {
        static let captionFont: CGFloat = 13
        static let captionX: CGFloat = 24
        static let captionHeight: CGFloat = 22
        static let sectionGap: CGFloat = 14
        static let cardGap: CGFloat = 12
        static let cardRadius: CGFloat = 20
        static let row: CGFloat = 52
        static let circle: CGFloat = 28
        static let glyph: CGFloat = 18
        static let tileRadius: CGFloat = 7
        static let glyphX: CGFloat = 16
        static let textX: CGFloat = 54
        static let rowFont: CGFloat = 17
        static let trailing: CGFloat = 14
    }
}
