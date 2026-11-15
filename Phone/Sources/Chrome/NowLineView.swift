import SwiftUI
import UIKit

/// The Now line: one line over the plate about the most important thing, a
/// task's step in words, what it needs, done. Folded with the chrome, one
/// short word beside the plate's capsule. Needs you: the color at once, the
/// words in place, a short push. The Mac hint is a small chip instead, with a
/// cross, that a swipe sweeps away too.
struct NowLineView: View {
    let item: NowItem
    let folded: Bool
    var isAccessible = true
    /// Takes a terminal notice away by swipe, or a chip by its cross too.
    var dismiss: (() -> Bool)? = nil
    /// A tap on the line (nil) or on its action capsule (the action's name).
    let tap: (String?) -> Void

    @State private var nudge = false
    /// The chip under a finger, or on its way out.
    @State private var swept: CGSize = .zero
    @State private var leaving = false

    var body: some View {
        ZStack {
            Group {
                if let chip = item.chip { chipFull(chip) }
                else if item.kind == .download { fileLine }
                else { full }
            }
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(isAccessible && !folded)
            .accessibilityHidden(!isAccessible || folded)
            mini.opacity(folded ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Capsule(style: .continuous))
        .glassCapsule()
        .scaleEffect(nudge ? Metrics.Now.nudgeScale : 1)
        .offset(swept)
        .opacity(1 - min(1, hypot(swept.width, swept.height) / Metrics.Now.sweepAway * 1.6))
        .onTapGesture { tap(nil) }
        .gesture(sweep, including: dismiss != nil && !folded && isAccessible ? .all : .none)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(isAccessible ? "chrome.now" : "")
        .accessibilityLabel(item.subtitle.isEmpty ? item.title : "\(item.title), \(item.subtitle)")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if item.chip != nil, let action = item.action { Button(action) { tap(action) } }
            if let dismiss { Button("Dismiss") { _ = dismiss() } }
        }
        .accessibilityHidden(!isAccessible)
        .allowsHitTesting(isAccessible)
        .onChange(of: item) { _, _ in
            swept = .zero
            leaving = false
        }
        .onChange(of: item.kind) { _, kind in
            guard isAccessible, kind == .warn, !Motion.disabled else { return }
            Motion.nowNudge.run({ nudge = true }) { Motion.nowNudge.run { nudge = false } }
        }
    }

    private var subtitleColor: Color {
        switch item.kind {
        case .warn: Ink.warn
        case .done: Ink.done
        default: Ink.secondary
        }
    }

    private var full: some View {
        HStack(spacing: Metrics.Now.gap) {
            NowIconView(icon: item.icon, size: Metrics.Now.icon)
                .frame(width: Metrics.Now.iconBox, height: Metrics.Now.iconBox)
            VStack(alignment: .leading, spacing: Metrics.Now.lineGap) {
                Text(item.title)
                    .font(.system(size: Metrics.Now.titleFont, weight: .semibold))
                    .tracking(-0.01 * Metrics.Now.titleFont)
                    .foregroundStyle(Ink.primary)
                Text(item.subtitle)
                    .font(.system(size: Metrics.Now.subtitleFont))
                    .tracking(-0.01 * Metrics.Now.subtitleFont)
                    .foregroundStyle(subtitleColor)
                    .contentTransition(.opacity)
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action = item.action {
                Button { tap(action) } label: {
                    Text(action)
                        .font(.system(size: Metrics.Now.actionFont, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, Metrics.Now.actionPadding)
                        .frame(height: Metrics.Now.actionHeight)
                        .background(Ink.warnFill, in: Capsule(style: .continuous))
                        // 32 to see, 44 to hit.
                        .frame(minHeight: Metrics.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(isAccessible && !folded ? "chrome.now.action" : "")
                .accessibilityHidden(!isAccessible || folded)
                .allowsHitTesting(isAccessible && !folded)
            }
            if let more = item.more {
                Text(more)
                    .font(.system(size: Metrics.Now.moreFont, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(.trailing, Metrics.Now.moreTrailing)
            }
        }
        .padding(.leading, Metrics.Now.leading)
        .padding(.trailing, Metrics.Now.trailing)
    }

    /// A file: its name and one word at the end, the percent, Open or Failed.
    private var fileLine: some View {
        HStack(spacing: Metrics.Now.gap) {
            NowIconView(icon: item.icon, size: Metrics.Now.icon)
                .frame(width: Metrics.Now.iconBox, height: Metrics.Now.iconBox)
            Text(item.title)
                .font(.system(size: Metrics.Now.titleFont, weight: .semibold))
                .tracking(-0.01 * Metrics.Now.titleFont)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !item.subtitle.isEmpty {
                Text(item.subtitle)
                    .font(.system(size: Metrics.Now.titleFont, weight: item.subtitle == "Open" ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(item.subtitle == "Open" ? Ink.unread : item.subtitle == "Failed" ? Ink.warn : Ink.secondary)
                    .contentTransition(.numericText())
                    .padding(.trailing, Metrics.Now.moreTrailing)
            }
        }
        .padding(.leading, Metrics.Now.leading)
        .padding(.trailing, Metrics.Now.trailing)
    }

    /// The Mac's tab as a chip: its site with the Mac's mark, "Figma · On your
    /// Mac", and a cross.
    private func chipFull(_ chip: NowItem.Chip) -> some View {
        typealias N = Metrics.Now
        return HStack(spacing: 0) {
            // As a web favicon wears a badge: a round bite out of the site's icon
            // by a mask, and the Mac's mark standing in it, no ring and no plate.
            ZStack(alignment: .bottomTrailing) {
                Favicon(icon: chip.icon, size: N.chipIcon)
                    .mask {
                        Rectangle()
                            .overlay(alignment: .bottomTrailing) {
                                Circle()
                                    .frame(width: N.chipCut, height: N.chipCut)
                                    .offset(x: N.chipBadgeOut + (N.chipCut - N.chipBadge) / 2,
                                            y: N.chipBadgeOut + (N.chipCut - N.chipBadge) / 2)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }
                Glyph(.macbook, size: N.chipBadgeGlyph, color: Ink.primary)
                    .frame(width: N.chipBadge, height: N.chipBadge)
                    .offset(x: N.chipBadgeOut, y: N.chipBadgeOut)
            }
            .frame(width: N.chipIcon, height: N.chipIcon)
            .padding(.leading, N.chipLeading)
            Text(chip.words)
                .font(.system(size: N.chipFont, weight: .medium))
                .tracking(-0.01 * N.chipFont)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, N.chipGap)
                .frame(maxWidth: .infinity, alignment: .leading)
            // A page the Mac sent says Open in words, on the cross's quiet
            // plate rather than a task's warning fill: nothing waits on you.
            if let action = item.action {
                Button { tap(action) } label: {
                    Text(action)
                        .font(.system(size: N.chipFont, weight: .semibold))
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, N.actionPadding)
                        .frame(height: N.chipCross)
                        .background(Capsule(style: .continuous).fill(Ink.primary.opacity(0.08)))
                        .frame(minHeight: N.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(isAccessible && !folded ? "chrome.now.action" : "")
                .padding(.leading, 4)
            }
            if let dismiss {
                Button {
                    if dismiss() { Haptics.play(.selection, reason: Haptics.Reason.nowDismissed) }
                } label: {
                    Glyph(.crossMedium, size: N.chipCrossGlyph, color: Ink.primary.opacity(0.6))
                        .frame(width: N.chipCross, height: N.chipCross)
                        .background(Circle().fill(Ink.primary.opacity(0.08)))
                        .frame(width: N.chipCrossHit, height: N.chipHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier(isAccessible && !folded ? "chrome.now.dismiss" : "")
                .padding(.leading, 4)
                .padding(.trailing, N.chipTrailing)
            }
        }
    }

    /// Swept aside or down: far enough or quick enough, it goes the way it was
    /// sent; a short flick springs back.
    private var sweep: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !leaving else { return }
                swept = CGSize(width: value.translation.width, height: max(0, value.translation.height))
            }
            .onEnded { value in
                guard !leaving else { return }
                let dx = value.translation.width, dy = max(0, value.translation.height)
                let far = Metrics.Now.sweepFar, quick = Metrics.Now.sweepFlick
                let sent = abs(dx) > far || dy > far
                    || abs(value.predictedEndTranslation.width) > quick || value.predictedEndTranslation.height > quick
                guard sent else {
                    Motion.letGoBack.run { swept = .zero }
                    return
                }
                leaving = true
                Haptics.play(.selection, reason: Haptics.Reason.nowDismissed)
                let away = Metrics.Now.sweepAway
                let out = abs(dx) >= dy ? CGSize(width: dx < 0 ? -away : away, height: 0) : CGSize(width: 0, height: away)
                Motion.letGo.run({ swept = out }) {
                    if dismiss?() != true {
                        leaving = false
                        Motion.letGoBack.run { swept = .zero }
                    }
                }
            }
    }

    private var mini: some View {
        HStack(spacing: Metrics.Now.minGap) {
            NowIconView(icon: item.icon, size: Metrics.Now.minIcon)
                .frame(width: Metrics.Now.minIconBox, height: Metrics.Now.minIconBox)
            Text(item.short)
                .font(.system(size: Metrics.Now.minFont, weight: .semibold))
                .tracking(-0.01 * Metrics.Now.minFont)
                .foregroundStyle(item.kind == .warn ? Ink.warn : Ink.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, Metrics.Now.minPadding)
    }
}

/// The Now line's icon: the site the Mac is on, the Mac, Yab's mark, the agent.
struct NowIconView: View {
    let icon: NowItem.Icon
    let size: CGFloat

    var body: some View {
        switch icon {
        case let .favicon(key):
            Favicon(icon: key, size: size)
        case let .glyph(name):
            // The prototype draws glyphs a little smaller than favicons in the same box.
            Glyph(name, size: size - 2)
        case .mark:
            YabMark(size: size)
        case .face:
            AgentFace(size: size - 2)
        case let .mac(mark):
            Glyph(mac: mark, size: size - 2)
        }
    }
}

/// Yab's mark, the glass wink.
struct YabMark: View {
    var size: CGFloat = 24

    var body: some View {
        Image("YabMark")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

extension NowItem {
    /// The chip's width: it hugs its words, and never outgrows the line.
    func chipWidth(screen: CGFloat) -> CGFloat? {
        guard let chip else { return nil }
        let words = (chip.words as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: Metrics.Now.chipFont, weight: .medium)]).width
        // Open, beside the cross, on its own plate.
        let action = action.map { ($0 as NSString).size(withAttributes: [
            .font: UIFont.systemFont(ofSize: Metrics.Now.chipFont, weight: .semibold)]).width + 2 * Metrics.Now.actionPadding + 4 } ?? 0
        return min(ceil(Metrics.Now.chipFixed + words + action), Metrics.Now.width(screen: screen))
    }
}
