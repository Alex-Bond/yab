import SwiftUI

/// The eyes in New Tab's field (Icons/Eyes.svg, EyesShut.svg): two ovals
/// looking down to the left. Shut, the lids come down over 84 % of each eye,
/// leaving a dark crescent's arc below so they still read as eyes, and the
/// pupils go. Drawn rather than swapped, so the lids move.
struct Eyes: View, Animatable {
    /// 0 open, 1 shut.
    var shut: CGFloat
    var color: Color

    var animatableData: CGFloat {
        get { shut }
        set { shut = newValue }
    }

    var body: some View {
        Canvas { context, canvas in
            // The SVG's own grid, 26 × 20, scaled to the frame.
            let k = canvas.width / Metrics.NewTab.eyes.width
            for cx in [7.0, 19.0] {
                let eye = CGRect(x: (cx - 5.2) * k, y: (10 - 7.6) * k, width: 10.4 * k, height: 15.2 * k)
                let oval = Path(ellipseIn: eye)
                // The lids: the eye's own oval, clipped to one ellipse hung
                // from the middle of the drawing's top, 75 % of its width
                // across and up to 84 % of its height down, so its edge
                // curves and leaves a crescent under each eye.
                if shut > 0.001 {
                    let rx = canvas.width * 0.75, ry = canvas.height * 0.84 * shut
                    let clip = Path(ellipseIn: CGRect(x: canvas.width / 2 - rx, y: -ry, width: rx * 2, height: ry * 2))
                    context.drawLayer { layer in
                        layer.clip(to: clip)
                        layer.fill(oval, with: .color(color))
                    }
                }
                context.stroke(oval, with: .color(color), lineWidth: 1.8 * k)
                // The pupils go in the first half of the lids' way.
                let pupil = max(0, 1 - shut * 2)
                if pupil > 0.001 {
                    let r = 2.5 * k
                    let dot = Path(ellipseIn: CGRect(x: (cx - 1.4) * k - r, y: 13 * k - r, width: r * 2, height: r * 2))
                    context.fill(dot, with: .color(color.opacity(pupil)))
                }
            }
        }
        .frame(width: Metrics.NewTab.eyes.width, height: Metrics.NewTab.eyes.height)
        .accessibilityHidden(true)
    }
}

/// The eyes as New Tab's switch: tap, and the lids come down and the word
/// Incognito opens beside them. 36 high, at least 40 wide.
struct EyesButton: View {
    let shut: Bool
    let dark: Bool
    let toggle: () -> Void
    @ScaledMetric(relativeTo: .subheadline) private var wordWidth = Metrics.NewTab.incognitoWidth

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Metrics.NewTab.eyesGap) {
                Group {
                    // An off label has no text layer for native detection
                    // to mistake for low-contrast visible words.
                    if shut {
                        Text("Incognito")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(dark ? Color.white.opacity(0.85) : Ink.primary)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: shut ? wordWidth : 0, alignment: .leading)
                .clipped()
                .animation(Motion.disabled ? nil : Motion.eyesWord.animation, value: shut)
                Eyes(shut: shut ? 1 : 0, color: dark ? Color.white : Ink.primary)
            }
            .padding(.horizontal, Metrics.NewTab.eyesPadding)
            .frame(minWidth: Metrics.NewTab.eyesMinWidth, minHeight: Metrics.NewTab.eyesHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("field.eyes")
        .accessibilityLabel("Incognito")
        .accessibilityValue(shut ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}
