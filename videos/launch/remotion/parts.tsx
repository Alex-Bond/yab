// The pieces the three films share: the website's paper, Yab's window as a
// framed shot, the pen, the keys as Yab draws them, the ending.
import React from "react";
import { AbsoluteFill, Easing, Img, interpolate, OffthreadVideo, Sequence, staticFile, useCurrentFrame } from "remotion";
import shots from "./shots.json";

export const FPS = 30;
export const SANS = '-apple-system, "SF Pro Display", "SF Pro Text", system-ui, sans-serif';
export const HAND = '"Caveat", "Bradley Hand", cursive';
export const INK = "#171717";
export const GROUND = "#F5F5F7";
export const PEN = "#8a5cf5";
export const VIOLET = "#9A6BFF";

const ease = Easing.bezier(0.2, 0.8, 0.2, 1);

/** 0 to 1 over [start, start + length), eased, clamped. */
export const ramp = (frame: number, start: number, length: number, easing = ease) =>
  interpolate(frame, [start, start + length], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing });

export const Fonts: React.FC = () => (
  <style>{`@font-face { font-family: "Caveat"; src: url(${staticFile("brand/Caveat.ttf")}) format("truetype"); font-weight: 400 700; }`}</style>
);

/** The website's ground: a dot grid on near white, and its grain. */
export const Paper: React.FC<{ dark?: boolean }> = ({ dark }) => dark ? (
  // On dark, no dots: only a breath of grain, or it reads as static.
  <AbsoluteFill style={{ backgroundImage: `url(${staticFile("brand/grain-on-dark.png")})`, backgroundSize: "128px 128px", opacity: 0.1 }} />
) : (
  <AbsoluteFill
    style={{
      backgroundColor: dark ? "#131314" : "#FBFBFB",
      backgroundImage: `radial-gradient(${dark ? "rgba(255,255,255,.075)" : "rgba(0,0,0,.1)"} 1.3px, transparent 1.6px)`,
      backgroundSize: "26px 26px",
      backgroundPosition: "13px 13px",
    }}
  >
    <AbsoluteFill
      style={{
        backgroundImage: `url(${staticFile(dark ? "brand/grain-on-dark.png" : "brand/grain-light.png")})`,
        backgroundSize: "128px 128px",
        opacity: dark ? 0.55 : 0.45,
        mixBlendMode: dark ? "screen" : "multiply",
      }}
    />
  </AbsoluteFill>
);

/** A shot of Yab by name: its picture if it was captured (shots.json),
 * else a quiet plate that says which live take goes there. */
export const shot = (name: string): string | null => ((shots as Record<string, string>)[name] ? staticFile("shots/" + (shots as Record<string, string>)[name]) : null);

/** A picture of the window from `at`: a still (shots/), or a live take
 * (takes/, recorded on an unlocked screen, docs/launch-videos.md) played
 * from `from` seconds in. */
type Slide = { name: string; at: number; take?: string; from?: number };

/** A slow zoom toward a point of the picture (0 to 1 in each axis), for the
 * pictures that come in during `beat` (all of them when it is left out). */
export type Push = { from: number; to: number; at: [number, number]; start: number; length: number; beat?: [number, number] };

/** Yab's window, framed as macOS frames it (rounded, shadowed), changing
 * picture at each slide's frame with a short crossfade. Each picture keeps
 * its own push while it fades, so a new beat never snaps the old one back. */
export const Window: React.FC<{
  slides: Slide[]; x: number; y: number; width: number; dark?: boolean;
  push?: Push | Push[];
  enter?: number; radius?: number;
  // Pieces of other frames laid over the picture, in its own proportions
  // (0 to 1 of its width and height), rising in at `at`.
  overlays?: { src: string; at: number; x: number; y: number; w: number }[];
}> = ({ slides, x, y, width, dark, push, enter = 0, radius = 18, overlays = [] }) => {
  const frame = useCurrentFrame();
  const height = (width * 1800) / 2880;
  const shown = ramp(frame, enter, 14);
  const pushes = push ? (Array.isArray(push) ? push : [push]) : [];
  // How a picture that came in at `since` is zoomed now.
  const pushed = (since: number): React.CSSProperties => {
    const p = pushes.find((p) => !p.beat || (since >= p.beat[0] && since < p.beat[1]));
    if (!p) return {};
    const zoom = p.from + (p.to - p.from) * ramp(frame, p.start, p.length, Easing.bezier(0.45, 0, 0.25, 1));
    return { transform: `scale(${zoom})`, transformOrigin: `${p.at[0] * 100}% ${p.at[1] * 100}%` };
  };
  return (
    <div
      style={{
        position: "absolute", left: x, top: y + (1 - shown) * 18, width, height, borderRadius: radius, overflow: "hidden",
        opacity: shown,
        boxShadow: dark
          ? "0 0 0 1px rgba(255,255,255,.10), 0 40px 120px rgba(0,0,0,.6), 0 0 160px rgba(154,107,255,.18)"
          : "0 0 0 1px rgba(0,0,0,.08), 0 24px 60px rgba(0,0,0,.14), 0 4px 14px rgba(0,0,0,.06)",
        // Yab's own shots are see-through where the window is glass: a
        // light ground under them, as the desktop would be.
        background: "#EEEEF1",
      }}
    >
      <div style={{ position: "absolute", inset: 0 }}>
        {slides.map((slide, i) => {
          const next = slides[i + 1];
          const opacity = i === 0 ? 1 : ramp(frame, slide.at, 10);
          const gone = next ? ramp(frame, next.at + 10, 1) : 0;
          const src = shot(slide.name);
          if (gone >= 1 || frame < slide.at - 1) return null;
          // What is laid over this picture goes with it, under the next one.
          const over = overlays.filter((o) => o.at >= slide.at && (!next || o.at < next.at) && frame >= o.at);
          return (
            <AbsoluteFill key={slide.name + i} style={{ opacity, ...pushed(slide.at) }}>
              {slide.take ? (
                <Sequence from={slide.at - 1} layout="none">
                  <OffthreadVideo src={staticFile("takes/" + slide.take)} startFrom={Math.round((slide.from ?? 0) * 30)} muted
                    style={{ position: "absolute", inset: 0, width: "100%", height: "100%", objectFit: "cover" }} />
                </Sequence>
              ) : src ? (
                <Img src={src} style={{ position: "absolute", inset: 0, width: "100%", height: "100%" }} />
              ) : (
                <AbsoluteFill style={{ background: dark ? "#202024" : "#EDEDF0", alignItems: "center", justifyContent: "center" }}>
                  <div style={{ font: `500 ${width / 40}px ${SANS}`, color: dark ? "#888" : "#999" }}>live take: {slide.name}</div>
                </AbsoluteFill>
              )}
              {over.map((o) => {
                const shown = ramp(frame, o.at, 12);
                return (
                  <Img key={o.src} src={staticFile(o.src)} style={{
                    position: "absolute", left: `${o.x * 100}%`, top: `${o.y * 100}%`, width: `${o.w * 100}%`,
                    opacity: shown, transform: `translateY(${(1 - shown) * 14}px)`,
                  }} />
                );
              })}
            </AbsoluteFill>
          );
        })}
      </div>
    </div>
  );
};

/** Words in the pen's hand, written out left to right. */
export const Hand: React.FC<{ text: string; at: number; x: number; y: number; size?: number; color?: string; rotate?: number; speed?: number }> = ({
  text, at, x, y, size = 46, color = PEN, rotate = -2, speed = 1,
}) => {
  const frame = useCurrentFrame();
  const length = Math.max(10, (text.length * 1.4) / speed);
  const shown = ramp(frame, at, length, Easing.linear);
  if (frame < at) return null;
  return (
    <div
      style={{
        position: "absolute", left: x, top: y, font: `600 ${size}px ${HAND}`, color, whiteSpace: "nowrap",
        transform: `rotate(${rotate}deg)`, clipPath: `inset(-20% ${100 - shown * 100}% -20% -2%)`,
      }}
    >
      {text}
    </div>
  );
};

/** A stroke of the pen: a path drawn from its start. */
export const Stroke: React.FC<{ d: string; at: number; length?: number; color?: string; width?: number; box: [number, number, number, number] }> = ({
  d, at, length = 14, color = PEN, width = 4, box,
}) => {
  const frame = useCurrentFrame();
  const drawn = ramp(frame, at, length, Easing.bezier(0.3, 0, 0.2, 1));
  if (frame < at) return null;
  const [x, y, w, h] = box;
  return (
    <svg style={{ position: "absolute", left: x, top: y, width: w, height: h, overflow: "visible" }} viewBox={`0 0 ${w} ${h}`}>
      <path d={d} fill="none" stroke={color} strokeWidth={width} strokeLinecap="round" strokeLinejoin="round" pathLength={1}
        strokeDasharray={1} strokeDashoffset={1 - drawn} />
    </svg>
  );
};

/** Keys drawn as Yab draws them (KeyArt), on plates. */
const KEYART: Record<string, string> = {
  "⌘": "M15 6v12a3 3 0 1 0 3-3H6a3 3 0 1 0 3 3V6a3 3 0 1 0-3 3h12a3 3 0 1 0-3-3",
  "⇧": "M12 3.5 3.5 12H8v8.5h8V12h4.5z",
  "⌥": "M3 3h6l6 18h6M14 3h7",
  "⌃": "m18 15-6-6-6 6",
  "↩": "M14 5h4.5a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3m4.5-4.5L3 14l4.5 4.5",
  "⇥": "M3 12h14m-5-5 5 5-5 5M21 5v14",
};

export const Keys: React.FC<{ keys: string[]; at: number; size?: number; dark?: boolean }> = ({ keys, at, size = 150, dark }) => {
  const frame = useCurrentFrame();
  return (
    <div style={{ display: "flex", gap: size * 0.16 }}>
      {keys.map((key, i) => {
        const pressed = ramp(frame, at + i * 3, 8);
        const press = interpolate(frame, [at + 12 + i * 3, at + 16 + i * 3, at + 22 + i * 3], [1, 0.92, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
        return (
          <div key={key + i} style={{
            width: size, height: size, borderRadius: size * 0.22, display: "flex", alignItems: "center", justifyContent: "center",
            background: dark ? "#232326" : "#fff", color: dark ? "#f2f2f2" : INK, opacity: pressed,
            transform: `translateY(${(1 - pressed) * 24}px) scale(${press})`,
            boxShadow: dark ? "0 0 0 1px rgba(255,255,255,.1), 0 10px 30px rgba(0,0,0,.5)" : "0 0 0 1px rgba(0,0,0,.08), 0 2px 0 rgba(0,0,0,.06), 0 14px 34px rgba(0,0,0,.10)",
          }}>
            {KEYART[key] ? (
              <svg width={size * 0.46} height={size * 0.46} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2.2} strokeLinecap="round" strokeLinejoin="round">
                <path d={KEYART[key]} />
              </svg>
            ) : (
              <span style={{ font: `600 ${size * 0.42}px ${SANS}` }}>{key}</span>
            )}
          </div>
        );
      })}
    </div>
  );
};

/** Big words that rise in. */
export const Words: React.FC<{ text: React.ReactNode; at: number; x: number; y: number; size?: number; color?: string; weight?: number; width?: number; out?: number }> = ({
  text, at, x, y, size = 72, color = INK, weight = 650, width, out,
}) => {
  const frame = useCurrentFrame();
  const shown = ramp(frame, at, 14);
  const gone = out !== undefined ? ramp(frame, out, 10) : 0;
  if (frame < at) return null;
  return (
    <div style={{
      position: "absolute", left: x, top: y, width, font: `${weight} ${size}px/1.08 ${SANS}`, letterSpacing: "-0.035em", color,
      opacity: shown * (1 - gone), transform: `translateY(${(1 - shown) * 16 - gone * 10}px)`,
    }}>
      {text}
    </div>
  );
};

/** The ending every film shares. */
export const Ending: React.FC<{ at: number; dark?: boolean; line?: string }> = ({ at, dark, line = "Yes, another browser." }) => {
  const frame = useCurrentFrame();
  const mark = ramp(frame, at, 20);
  const words = ramp(frame, at + 10, 16);
  const small = ramp(frame, at + 22, 16);
  const ink = dark ? "#EDEDED" : INK;
  return (
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
      <Img src={staticFile("brand/mark.png")} style={{ width: 200, opacity: mark, transform: `translateY(${(1 - mark) * 24}px) scale(${0.94 + 0.06 * mark})` }} />
      <div style={{ marginTop: 40, font: `650 88px/1 ${SANS}`, letterSpacing: "-0.04em", color: ink, opacity: words, transform: `translateY(${(1 - words) * 14}px)` }}>
        {line.replace(/\.$/, "")}<span style={{ color: VIOLET }}>.</span>
      </div>
      <div style={{ marginTop: 26, font: `500 30px ${SANS}`, color: dark ? "rgba(237,237,237,.62)" : "rgba(23,23,23,.55)", opacity: small }}>
        Free for Mac · yetanotherbrowser.com
      </div>
    </AbsoluteFill>
  );
};
