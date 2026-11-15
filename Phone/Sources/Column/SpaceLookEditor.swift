import SwiftUI
import UIKit

/// A space's look, edited as the Mac's Look card edits it (ColorEditor,
/// LookPresetRow, LookSlider in Sources/Fast): the dotted field with the
/// main color and its linked ones, − and + at its foot, the presets under
/// it, then Transparency's wave and Grain's dots. Sizes, curves and
/// feedback are the Mac's; only the width is the phone's.
struct SpaceLookEditor: View {
    let look: SpaceLook
    let change: (SpaceLook) -> Void
    let ended: () -> Void
    let diagnosticOwner: String?
    @State private var primary: LookColor
    @State private var harmony: LookHarmony
    @State private var held: Int?? = nil
    @State private var grab: CGSize?
    @State private var page: Int
    /// The field's dot under the handle last ticked, and when.
    @State private var lastDot: (Int, Int)?
    @State private var lastTick: Date = .distantPast

    private typealias L = Metrics.LookEditor

    init(look: SpaceLook, diagnosticOwner: String? = nil, change: @escaping (SpaceLook) -> Void, ended: @escaping () -> Void) {
        self.look = look
        self.change = change
        self.ended = ended
        self.diagnosticOwner = diagnosticOwner
        let primary = LookColor(look.primary)
        _primary = State(initialValue: primary)
        _harmony = State(initialValue: LookHarmony(primary: primary, colors: look.colors))
        _page = State(initialValue: LookPresets.page(of: look))
    }

    var body: some View {
        VStack(spacing: L.sliderGroupGap) {
            VStack(spacing: L.presetGap) {
                field
                LookPresetRow(page: $page, selected: LookPresets.place(of: look)) { pick($0) }
            }
            // Grain, worn by the page, the spaces' card and All Tabs. Transparency
            // is the Mac's window's over its desktop: it has no meaning here and
            // rides along in the look untouched.
            LookAmountSlider(value: look.grain, kind: .grain, id: "space.look.grain", ended: ended) { value in
                var next = look; next.setGrain((value * 20).rounded() / 20); change(next)
            }
            .frame(height: L.sliderHeight)
            drawingsSection
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.look.editor")
        .onAppear { trace("render.appear") }
        .onChange(of: look.primary) { _, color in
            // Changed elsewhere (sync, another page): read it again.
            guard held == nil, color != primary.rgb else { return }
            primary = LookColor(color); harmony = LookHarmony(primary: primary, colors: look.colors)
        }
    }

    // MARK: - drawings

    /// The Mac's Drawings: None, Browser or Life as tiles wearing the look,
    /// and their strength once a set is picked.
    private var drawingsSection: some View {
        let picked = look.drawings
        return VStack(spacing: L.drawingsGap) {
            HStack {
                Text("Drawings").font(.subheadline.weight(.semibold))
                Spacer()
                if !picked.isEmpty {
                    Text("\(Int((look.drawingsStrength * 100).rounded()))%").font(.subheadline).monospacedDigit().foregroundStyle(Ink.secondary)
                }
            }
            HStack(spacing: L.tileGap) {
                drawingTile(nil, picked: picked)
                ForEach(LookDrawings.Set.allCases, id: \.self) { drawingTile($0, picked: picked) }
            }
            if !picked.isEmpty {
                LookAmountSlider(value: look.drawingsStrength, kind: .drawings, id: "space.look.drawings", ended: ended) { value in
                    var next = look; next.setDrawingsStrength(value); change(next)
                }
                .frame(height: L.sliderHeight)
            }
        }
        .padding(.top, L.drawingsTop)
    }

    private func drawingTile(_ set: LookDrawings.Set?, picked: String) -> some View {
        let on = (set?.rawValue ?? "") == picked
        let shape = RoundedRectangle(cornerRadius: L.tileRadius, style: .continuous)
        return Button {
            Haptics.play(.selection, reason: Haptics.Reason.lookPick)
            var next = look
            next.setDrawings(set?.rawValue ?? "")
            if set != nil, look.drawings.isEmpty { next.setDrawingsStrength(LookDrawings.standard) }
            change(next); ended()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    SpaceLookWash(look: look)
                    if let set { LookDrawingsFill(drawings: set.rawValue, strength: 1, ground: look.primary) }
                }
                .frame(height: L.tileHeight)
                .clipShape(shape)
                .overlay(shape.strokeBorder(Ink.primary.opacity(on ? 1 : 0.12), lineWidth: on ? 2 : 0.5))
                Text(set?.title ?? "None").font(.caption).foregroundStyle(on ? Ink.primary : Ink.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LookPresetPress())
        .accessibilityLabel(set.map { "\($0.title) drawings" } ?? "No drawings")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("space.look.drawings.\(set?.rawValue ?? "none")")
    }

    // MARK: - the field

    private var field: some View {
        GeometryReader { geo in
            let size = CGSize(width: geo.size.width, height: geo.size.height - L.footRoom)
            let travel = CGSize(width: max(1, size.width - L.dot), height: max(1, size.height - L.dot))
            let colors = harmony.colors(from: primary)
            let main = location(primary.point, travel: travel)
            ZStack(alignment: .topLeading) {
                LookFieldDots(lightness: primary.lightness, size: size, travel: travel, lens: main)
                    .equatable()
                    .frame(width: size.width, height: size.height)
                    .accessibilityHidden(true)
                ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                    handle(color, linked: index, travel: travel)
                }
                handle(primary, linked: nil, travel: travel)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(drag(travel: travel, colors: colors))
            .coordinateSpace(name: "space.look.field")
            // − and + in the 28 points under the dots, 2 off the field's foot.
            // (A 24 plate's middle 14 under the dots, in its finger's room.)
            .overlay(alignment: .bottom) { plusMinus.offset(y: L.footRoom - L.footPad - 12 + Metrics.touch / 2) }
        }
        // The Mac's field: 0.75 of its width.
        .aspectRatio(4 / 3, contentMode: .fit)
        .background(Ink.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: L.fieldRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: L.fieldRadius, style: .continuous))
    }

    /// A press takes the main color within its reach, else the nearest
    /// linked one within its own, else the main jumps to the finger.
    private func drag(travel: CGSize, colors: [LookColor]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("space.look.field"))
            .onChanged { value in
                if held == nil {
                    let at = value.startLocation
                    let main = location(primary.point, travel: travel)
                    if hypot(at.x - main.x, at.y - main.y) <= L.dot / 2 {
                        held = .some(nil); grab = CGSize(width: at.x - main.x, height: at.y - main.y)
                    } else if let (index, center) = colors.enumerated()
                        .map({ ($0.offset, location($0.element.point, travel: travel)) })
                        .filter({ hypot(at.x - $0.1.x, at.y - $0.1.y) <= L.linkedDot / 2 })
                        .min(by: { hypot(at.x - $0.1.x, at.y - $0.1.y) < hypot(at.x - $1.1.x, at.y - $1.1.y) }) {
                        held = .some(index); grab = CGSize(width: at.x - center.x, height: at.y - center.y)
                    } else {
                        held = .some(nil); grab = .zero
                    }
                }
                let at = CGPoint(x: value.location.x - (grab?.width ?? 0), y: value.location.y - (grab?.height ?? 0))
                tickAcross(at)
                let point = normalized(at, travel: travel)
                if case let .some(.some(index)) = held { harmony.move(index, to: point, from: primary) }
                else { primary.move(to: point) }
                publish()
            }
            .onEnded { _ in
                withAnimation(.snappy(duration: 0.14)) { held = nil }
                grab = nil
                lastDot = nil
                trace("handle.ended")
                ended()
            }
    }

    private func handle(_ color: LookColor, linked: Int?, travel: CGSize) -> some View {
        let main = linked == nil
        let side = main ? L.dot : L.linkedDot
        let grabbed: Bool = {
            if case let .some(index) = held { return index == linked }
            return false
        }()
        return Circle().fill(Color(rgb: color.rgb))
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .overlay { if main { Circle().strokeBorder(.black.opacity(0.14), lineWidth: 0.5).padding(-0.5) } }
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .scaleEffect(grabbed ? 1.1 : 1)
            .animation(.snappy(duration: 0.14), value: grabbed)
            .position(location(color.point, travel: travel))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(linked.map { "Linked color \($0 + 1)" } ?? "Main color")
            .accessibilityValue(SpaceLook.hex(color.rgb))
            .accessibilityIdentifier(linked.map { "space.look.link.\($0)" } ?? "space.look.main")
            .accessibilityAdjustableAction { direction in
                adjust(linked, hue: direction == .increment ? 0.05 : -0.05, reach: 0)
            }
            .accessibilityAction(named: "More color") { adjust(linked, hue: 0, reach: 0.05) }
            .accessibilityAction(named: "Less color") { adjust(linked, hue: 0, reach: -0.05) }
    }

    /// − and +: the Mac's quiet 24 point plates at the field's foot, each in
    /// a finger's room.
    private var plusMinus: some View {
        HStack(spacing: L.plusGap) {
            Button { remove() } label: { Image(systemName: "minus") }
                .buttonStyle(LookPlateStyle())
                .disabled(harmony.links.isEmpty)
                .accessibilityLabel("Remove color").accessibilityIdentifier("space.look.remove")
            Button { add() } label: { Image(systemName: "plus") }
                .buttonStyle(LookPlateStyle())
                .disabled(harmony.links.count >= 2)
                .accessibilityLabel("Add color").accessibilityIdentifier("space.look.add")
        }
        .font(.system(size: 12, weight: .medium))
    }

    /// A soft tick each time the handle crosses into the next dot of the
    /// field, as a finger feels a ratchet; never closer than 35 ms apart.
    private func tickAcross(_ at: CGPoint) {
        let dot = (Int((at.x / L.dotStep).rounded(.down)), Int((at.y / L.dotStep).rounded(.down)))
        defer { lastDot = dot }
        guard let last = lastDot, last != dot, Date().timeIntervalSince(lastTick) > 0.035 else { return }
        lastTick = Date()
        Haptics.play(.selection, reason: Haptics.Reason.lookDot)
    }

    private func location(_ point: CGPoint, travel: CGSize) -> CGPoint {
        CGPoint(x: L.dot / 2 + point.x * travel.width, y: L.dot / 2 + point.y * travel.height)
    }
    private func normalized(_ point: CGPoint, travel: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - L.dot / 2) / travel.width)),
                y: min(1, max(0, (point.y - L.dot / 2) / travel.height)))
    }
    private func publish() {
        var next = look; next.setPalette(primary, following: harmony.colors(from: primary))
        trace("publish", published: next)
        change(next)
    }
    private func trace(_ event: String, published: SpaceLook? = nil) {
        guard let diagnosticOwner else { return }
        LookEditDiagnostics.record(event, owner: diagnosticOwner, look: published ?? look,
                                   links: harmony.links.count, primary: primary,
                                   following: harmony.colors(from: primary))
    }
    private func adjust(_ linked: Int?, hue: Double, reach: Double) {
        if let linked, harmony.links.indices.contains(linked) {
            harmony.links[linked].hue = LookColor.turn(harmony.links[linked].hue + hue * 2 * .pi)
            harmony.links[linked].reach += reach
        } else { primary.hue = LookColor.turn(primary.hue + hue * 2 * .pi); primary.reach = SpaceLook.unit(primary.reach + reach) }
        publish(); ended()
    }
    /// +: the colors part to even places, two opposite, three a third apart.
    private func add() {
        guard harmony.links.count < 2 else { return }
        Haptics.play(.light, reason: Haptics.Reason.lookPick)
        withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) { harmony = .suggested(extras: harmony.links.count + 1) }
        publish(); ended()
    }
    /// −: the last linked color goes at once, the rest glide to even places.
    private func remove() {
        guard !harmony.links.isEmpty else { return }
        Haptics.play(.light, reason: Haptics.Reason.lookPick)
        var quiet = Transaction(animation: nil); quiet.disablesAnimations = true
        withTransaction(quiet) { harmony.links.removeLast() }
        let left = harmony.links.count
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.75)) { harmony = .suggested(extras: left) }
            publish(); ended()
        }
    }
    /// A preset: the main dot springs to it, its linked colors with it.
    private func pick(_ preset: LookPresets.Preset) {
        Haptics.play(.selection, reason: Haptics.Reason.lookPick)
        let next = LookColor(preset.main)
        withAnimation(.spring(response: 0.27, dampingFraction: 0.65)) {
            primary = next
            harmony = LookHarmony(primary: next, colors: preset.links)
        }
        publish(); ended()
    }
}

/// The field's dots, a dot every 10 points from 5, each the color under it
/// on the hidden wheel, swelling near the main handle (the Mac's FieldDots).
private struct LookFieldDots: View, Equatable {
    let lightness: Double
    let size: CGSize
    let travel: CGSize
    let lens: CGPoint
    private typealias L = Metrics.LookEditor

    var body: some View {
        let lattice = LookLattice.shared.colors(lightness: lightness, size: size, travel: travel)
        Canvas { context, _ in
            for dot in lattice {
                let near = hypot(dot.at.x - lens.x, dot.at.y - lens.y)
                let radius = 1.6 + 2.2 * exp(-(near * near) / (2 * 24 * 24))
                context.fill(Path(ellipseIn: CGRect(x: dot.at.x - radius, y: dot.at.y - radius, width: radius * 2, height: radius * 2)),
                             with: .color(Color(rgb: dot.color)))
            }
        }
    }
}

/// The field's printed colors for a lightness and a size, kept: the gamut
/// search per dot is the expensive part, and a drag only moves the lens.
@MainActor
private final class LookLattice {
    static let shared = LookLattice()
    struct Dot { let at: CGPoint; let color: RGB }
    private var key: (Double, CGSize)?
    private var dots: [Dot] = []

    func colors(lightness: Double, size: CGSize, travel: CGSize) -> [Dot] {
        // Printed between 0.55 and 0.75, as the Mac prints it.
        let printed = min(0.75, max(0.55, lightness))
        if let key, key.0 == printed, key.1 == size { return dots }
        var made: [Dot] = []
        let step = Metrics.LookEditor.dotStep, half = Metrics.LookEditor.dot / 2
        var y = step / 2
        while y < size.height {
            var x = step / 2
            while x < size.width {
                let across = min(1, max(0, (x - half) / travel.width)), down = min(1, max(0, (y - half) / travel.height))
                var color = LookColor(lightness: printed, reach: 0, hue: across * 2 * .pi)
                color.move(to: CGPoint(x: across, y: down))
                made.append(Dot(at: CGPoint(x: x, y: y), color: color.rgb))
                x += step
            }
            y += step
        }
        key = (printed, size)
        dots = made
        return made
    }
}

/// The Mac's quiet small square: a 24 point plate, lit while pressed, in a
/// finger's room.
private struct LookPlateStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? Ink.primary : Ink.primary.opacity(0.72))
            .frame(width: 24, height: 24)
            .background(Ink.primary.opacity(configuration.isPressed ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: configuration.isPressed ? 0.16 : 0.28, dampingFraction: 1), value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.72)
            .frame(width: Metrics.touch, height: Metrics.touch)
            .contentShape(Rectangle())
    }
}

// MARK: - presets

/// The Mac's five pages of nine (LookPresets in LookHarmony.swift): flat
/// colors, three-color gradients, pastels, muted darks, grays.
enum LookPresets {
    struct Preset: Equatable { let main: RGB; let links: [RGB] }
    private static func hex(_ v: UInt32) -> RGB { RGB(Int(v >> 16 & 255), Int(v >> 8 & 255), Int(v & 255)) }
    private static func flat(_ values: [UInt32]) -> [Preset] { values.map { Preset(main: hex($0), links: []) } }
    static let pages: [[Preset]] = [
        flat([0xF2E9E3, 0xEC8FBB, 0xA0689A, 0xE54C6E, 0xF37C5A, 0xF3D85E, 0x44FE96, 0x74BFD6, 0x666587]),
        [(0xF2E9E3, [0xF1E2E7, 0xEFF2E5]), (0xEC8FBB, [0xE68CE7, 0xE9AA9C]), (0xA0689A, [0x9F6A80, 0x886E9D]),
         (0xF37C5A, [0xF23B97, 0xEDF349]), (0xF3ED6E, [0xF6BB6D, 0xFAA68E]), (0xB7FF79, [0xDDEB78, 0xE3BD78]),
         (0x72F2E6, [0x69E7B9, 0x8C95E0]), (0x938EDC, [0x8DABDA, 0x8DBCD0]), (0x666587, [0x7D5F88, 0x628087])]
            .map { Preset(main: hex($0.0), links: $0.1.map(hex)) },
        flat([0xFEFBFA, 0xFFE9F3, 0xF1D1EC, 0xFFCBD1, 0xFFE0D3, 0xFFF9E5, 0xDEFDEB, 0xDCF3FC, 0xC5C6E5]),
        flat([0x4E3A5A, 0x693558, 0x8F4042, 0xB16D40, 0xD7B35D, 0xCDCCA4, 0x7AA982, 0x226149, 0x26456B]),
        flat([0xFFFFFF, 0xE5E5E5, 0xCCCCCC, 0xB2B2B2, 0x808080, 0x666666, 0x333333, 0x1A1A1A, 0x000000]),
    ]
    /// The page the look came from, or the first.
    static func page(of look: SpaceLook) -> Int { place(of: look)?.page ?? 0 }

    /// Where the look's colors are a preset, if they are.
    static func place(of look: SpaceLook) -> (page: Int, index: Int)? {
        for (p, presets) in pages.enumerated() {
            if let i = presets.firstIndex(where: { $0.main == look.primary && $0.links == look.colors }) { return (p, i) }
        }
        return nil
    }
}

/// ‹ nine dots ›, a page at a time on a spring with no give, faded at both
/// ends (the Mac's LookPresetRow).
private struct LookPresetRow: View {
    @Binding var page: Int
    let selected: (page: Int, index: Int)?
    let pick: (LookPresets.Preset) -> Void
    @Namespace private var ring
    /// The finger on the row: how far it has pulled the pages.
    @GestureState private var pull: CGFloat = 0
    private typealias L = Metrics.LookEditor

    var body: some View {
        HStack(spacing: 0) {
            Button { slide(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(LookPlateStyle()).disabled(page == 0)
                .accessibilityLabel("Previous Colors").accessibilityIdentifier("space.look.presets.back")
            GeometryReader { geo in
                let track = geo.size.width
                HStack(spacing: 0) {
                    ForEach(Array(LookPresets.pages.enumerated()), id: \.offset) { n, presets in
                        HStack(spacing: 0) {
                            ForEach(Array(presets.enumerated()), id: \.offset) { i, preset in
                                let chosen = selected.map { $0.page == n && $0.index == i } ?? false
                                Button { pick(preset) } label: {
                                    Circle()
                                        .fill(LinearGradient(colors: ([preset.main] + preset.links.reversed()).map { Color(rgb: $0) },
                                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                                        .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 1.5))
                                        .frame(width: L.presetDot, height: L.presetDot)
                                        .scaleEffect(chosen ? 0.82 : 1)
                                        // The chosen one wears a ring that springs over from the last.
                                        .background {
                                            if chosen {
                                                Circle().strokeBorder(Ink.primary, lineWidth: 2)
                                                    .frame(width: L.presetDot + 8, height: L.presetDot + 8)
                                                    .matchedGeometryEffect(id: "ring", in: ring)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, minHeight: Metrics.touch)
                                        .contentShape(Rectangle())
                                }
                                .accessibilityAddTraits(chosen ? .isSelected : [])
                                .buttonStyle(LookPresetPress())
                                .accessibilityLabel(SpaceLook.hex(preset.main))
                                .accessibilityIdentifier("space.look.preset.\(n).\(i)")
                            }
                        }
                        .frame(width: track)
                    }
                }
                .offset(x: -CGFloat(page) * track + resisted(pull, track: track))
                .frame(width: track, alignment: .leading)
                .animation(.spring(response: 0.27, dampingFraction: 0.65), value: selected.map { $0.page * 100 + $0.index })
                // A swipe across the dots turns the page, as the Mac's ‹ › do.
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 8)
                    .updating($pull) { value, pull, _ in pull = value.translation.width }
                    .onEnded { value in
                        let moved = value.predictedEndTranslation.width
                        if moved < -track / 3 { slide(1) } else if moved > track / 3 { slide(-1) }
                    })
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 3 / track),
                                             .init(color: .black, location: 1 - 3 / track), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            }
            .frame(height: Metrics.touch)
            Button { slide(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(LookPlateStyle()).disabled(page == LookPresets.pages.count - 1)
                .accessibilityLabel("More Colors").accessibilityIdentifier("space.look.presets.more")
        }
        .font(.system(size: 12, weight: .semibold))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("space.look.presets")
    }

    private func slide(_ by: Int) {
        let next = min(LookPresets.pages.count - 1, max(0, page + by))
        guard next != page else { Haptics.play(.light, reason: Haptics.Reason.lookEnd); return }
        Haptics.play(.selection, reason: Haptics.Reason.lookPage)
        withAnimation(.spring(response: 0.32, dampingFraction: 1)) { page = next }
    }

    /// Past the first or the last page the row gives a third as much.
    private func resisted(_ pull: CGFloat, track: CGFloat) -> CGFloat {
        let atEdge = (page == 0 && pull > 0) || (page == LookPresets.pages.count - 1 && pull < 0)
        return atEdge ? pull / 3 : pull
    }
}

private struct LookPresetPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: configuration.isPressed ? 0.16 : 0.28, dampingFraction: 1), value: configuration.isPressed)
    }
}

// MARK: - sliders

/// Transparency's wave and Grain's dots with the Mac's pill (LookSlider):
/// a native slider takes the finger and VoiceOver; its track is drawn here,
/// lit up to the pill; a tick at each step crossed and a knock at either
/// end, as the Mac's trackpad gives them.
private struct LookAmountSlider: UIViewRepresentable {
    enum Kind { case transparency, grain, drawings }
    let value: Double
    let kind: Kind
    let id: String
    let ended: () -> Void
    let change: (Double) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> LookAmountView {
        let view = LookAmountView(kind: kind)
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        view.slider.addTarget(context.coordinator, action: #selector(Coordinator.released), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        view.slider.didAdjust = { [weak coordinator = context.coordinator] in coordinator?.released() }
        return view
    }
    func updateUIView(_ view: LookAmountView, context: Context) {
        context.coordinator.parent = self
        view.overrideUserInterfaceStyle = context.environment.colorScheme == .dark ? .dark : .light
        if !view.slider.isTracking { view.slider.value = Float(value) }
        view.slider.accessibilityLabel = kind == .transparency ? "Transparency" : kind == .grain ? "Grain" : "Drawings"
        view.slider.accessibilityValue = "\(Int((value * 100).rounded()))%"
        view.slider.accessibilityIdentifier = id
        view.refresh()
    }
    @MainActor
    final class Coordinator: NSObject {
        var parent: LookAmountSlider
        private var last: Double?
        init(_ parent: LookAmountSlider) { self.parent = parent }
        @objc func began() { last = parent.value }
        @objc func changed(_ slider: UISlider) {
            var value = Double(slider.value)
            if parent.kind == .grain { value = (value * 20).rounded() / 20 }
            let old = last ?? parent.value
            last = value
            if value != old {
                let step = parent.kind == .transparency ? 0.2 : 0.1
                if value == 0 || value == 1 { Haptics.play(.rigid, reason: Haptics.Reason.lookEnd) }
                else if Self.crossed(old, value, every: step) { Haptics.play(.selection, reason: Haptics.Reason.lookStep) }
            }
            parent.change(value)
            (slider.superview as? LookAmountView)?.refresh(value: value)
        }
        @objc func released() { last = nil; parent.ended() }
        nonisolated static func crossed(_ a: Double, _ b: Double, every step: Double) -> Bool {
            let low = min(a, b), high = max(a, b)
            return (low / step - 1e-9).rounded(.up) <= (high / step + 1e-9).rounded(.down)
        }
    }
}

private final class LookAmountNativeSlider: UISlider {
    var didAdjust: (() -> Void)?
    var touching: ((Bool) -> Void)?
    override func accessibilityIncrement() { super.accessibilityIncrement(); sendActions(for: .valueChanged); didAdjust?() }
    override func accessibilityDecrement() { super.accessibilityDecrement(); sendActions(for: .valueChanged); didAdjust?() }
    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool { touching?(true); return super.beginTracking(touch, with: event) }
    override func endTracking(_ touch: UITouch?, with event: UIEvent?) { super.endTracking(touch, with: event); touching?(false) }
    override func cancelTracking(with event: UIEvent?) { super.cancelTracking(with: event); touching?(false) }
    /// The track is drawn by the view under it: the slider's own is clear.
    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        CGRect(x: Metrics.LookEditor.trackInset, y: bounds.midY - 1, width: bounds.width - 2 * Metrics.LookEditor.trackInset, height: 2)
    }
}

private final class LookAmountView: UIView {
    let slider = LookAmountNativeSlider()
    let kind: LookAmountSlider.Kind
    private let label = UILabel()
    private let labelPlate = UIView()
    private var shown: Double = 0
    private var held = false
    /// The grain's 170 dots, the same scatter every time, denser to the right.
    private static let grains: [(x: CGFloat, y: CGFloat, r: CGFloat)] = {
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        var made: [(CGFloat, CGFloat, CGFloat)] = []
        while made.count < 170 {
            let x = next()
            if next() < 0.12 + x * 0.88 { made.append((x, next() * 2 - 1, 0.8 + next() * 0.6)) }
        }
        return made.map { (x: $0.0, y: $0.1, r: $0.2) }
    }()

    init(kind: LookAmountSlider.Kind) {
        self.kind = kind
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        // None of the system's track, its marks included: the track is drawn here.
        slider.setMinimumTrackImage(UIImage(), for: .normal)
        slider.setMaximumTrackImage(UIImage(), for: .normal)
        // The Mac's pill, a finger's size: 14 by 34, 38 while held.
        slider.setThumbImage(Self.pill(height: 34), for: .normal)
        slider.setThumbImage(Self.pill(height: 38), for: .highlighted)
        slider.touching = { [weak self] on in self?.hold(on) }
        addSubview(slider)
        labelPlate.isUserInteractionEnabled = false
        labelPlate.alpha = 0
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        labelPlate.addSubview(label)
        addSubview(labelPlate)
    }
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// The Mac's pill: white, a hairline and its shadow, in room for the
    /// shadow.
    private static func pill(height: CGFloat) -> UIImage {
        let pad: CGFloat = 4, wide: CGFloat = 14
        let size = CGSize(width: wide + pad * 2, height: 38 + pad * 2)
        return UIGraphicsImageRenderer(size: size).image { context in
            let rect = CGRect(x: pad, y: (size.height - height) / 2, width: wide, height: height)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: wide / 2)
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 4, color: UIColor.black.withAlphaComponent(0.25).cgColor)
            UIColor.white.setFill(); path.fill()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.withAlphaComponent(0.22).setStroke()
            let ring = UIBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), cornerRadius: wide / 2 - 0.25); ring.lineWidth = 0.5; ring.stroke()
        }
    }

    private func hold(_ on: Bool) {
        held = on
        UIView.animate(withDuration: 0.14) { self.labelPlate.alpha = on ? 1 : 0 }
        refresh()
    }

    func refresh(value: Double? = nil) {
        if let value { shown = value } else { shown = Double(slider.value) }
        let percent = Int((shown * 100).rounded())
        label.text = switch kind {
        case .transparency: "Transparency \(percent)%"
        case .grain: percent == 0 ? "No grain" : "Grain \(percent)%"
        case .drawings: "Drawings \(percent)%"
        }
        label.textColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.11, alpha: 1) : .white }
        labelPlate.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.09, alpha: 1) }
        label.sizeToFit()
        let plate = CGSize(width: label.bounds.width + 12, height: label.bounds.height + 4)
        let x = Metrics.LookEditor.trackInset + CGFloat(shown) * (bounds.width - 2 * Metrics.LookEditor.trackInset)
        labelPlate.frame = CGRect(x: min(max(0, x - plate.width / 2), bounds.width - plate.width), y: -8 - plate.height / 2,
                                  width: plate.width, height: plate.height)
        labelPlate.layer.cornerRadius = plate.height / 2
        label.frame = CGRect(x: 6, y: 2, width: label.bounds.width, height: label.bounds.height)
        setNeedsDisplay()
    }

    override func layoutSubviews() { super.layoutSubviews(); slider.frame = bounds; refresh() }

    override func draw(_ rect: CGRect) {
        let inset = Metrics.LookEditor.trackInset
        let width = max(1, bounds.width - inset * 2), mid = bounds.midY
        let ink = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.93, alpha: 1) : UIColor(white: 0.09, alpha: 1) }
        if kind == .transparency {
            // Five periods across; the wave stills past the pill.
            let cut = CGFloat(shown) * width
            let path = UIBezierPath()
            var t: CGFloat = 0
            while t <= width {
                let amp = t < cut ? 6 : 6 * exp(-(t - cut) / 10)
                let point = CGPoint(x: inset + t, y: mid - amp * sin(t / width * 5 * 2 * .pi))
                if t == 0 { path.move(to: point) } else { path.addLine(to: point) }
                t += 1
            }
            path.lineWidth = 2; path.lineCapStyle = .round; path.lineJoinStyle = .round
            ink.withAlphaComponent(0.55).setStroke(); path.stroke()
        } else if kind == .drawings {
            // The Mac's drawings track: small crosses, lit up to the pill.
            let count = 21
            for i in 0..<count {
                let x = CGFloat(i) / CGFloat(count - 1)
                let c = CGPoint(x: inset + x * width, y: mid), r: CGFloat = 2.5
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: c.x - r, y: c.y)); cross.addLine(to: CGPoint(x: c.x + r, y: c.y))
                cross.move(to: CGPoint(x: c.x, y: c.y - r)); cross.addLine(to: CGPoint(x: c.x, y: c.y + r))
                cross.lineWidth = 1.2; cross.lineCapStyle = .round
                ink.withAlphaComponent(x <= CGFloat(shown) ? 0.72 : 0.16).setStroke(); cross.stroke()
            }
        } else {
            for grain in Self.grains {
                let center = CGPoint(x: inset + grain.x * width, y: mid + grain.y * 10)
                ink.withAlphaComponent(grain.x <= CGFloat(shown) ? 0.72 : 0.16).setFill()
                UIBezierPath(ovalIn: CGRect(x: center.x - grain.r, y: center.y - grain.r, width: grain.r * 2, height: grain.r * 2)).fill()
            }
        }
    }
}

extension Metrics {
    /// The Mac's Look editor (Sources/Fast/SpaceLook.swift, LookSlider.swift).
    enum LookEditor {
        static let dot: CGFloat = 36
        static let linkedDot: CGFloat = 24
        static let dotStep: CGFloat = 10
        static let footRoom: CGFloat = 28
        static let footPad: CGFloat = 2
        static let fieldRadius: CGFloat = 8
        static let plusGap: CGFloat = 4
        static let presetDot: CGFloat = 20
        static let presetGap: CGFloat = 8
        static let sliderGroupGap: CGFloat = 12
        static let sliderGap: CGFloat = 4
        /// The sliders a finger's height and then some (the Mac's are 32):
        /// 44 came out 43.7 on the pixel grid.
        static let sliderHeight: CGFloat = 48
        static let trackInset: CGFloat = 7
        static let drawingsTop: CGFloat = 8
        static let drawingsGap: CGFloat = 10
        static let tileGap: CGFloat = 8
        static let tileHeight: CGFloat = 44
        static let tileRadius: CGFloat = 8
    }
}
