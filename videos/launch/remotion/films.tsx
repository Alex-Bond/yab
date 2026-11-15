// The three films (docs/launch-videos.md has the shot lists).
import React from "react";
import { AbsoluteFill, Audio, interpolate, staticFile, useCurrentFrame } from "remotion";
import { Ending, Fonts, Hand, INK, Keys, Paper, PEN, Push, ramp, SANS, Stroke, VIOLET, Window, Words } from "./parts";

const fadeOut = (frame: number, total: number) => interpolate(frame, [total - 45, total - 8], [1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
const Bed: React.FC<{ name: string; total: number; volume?: number }> = ({ name, total, volume = 0.8 }) => (
  <Audio src={staticFile(`audio/${name}.m4a`)} volume={(f) => volume * Math.min(1, f / 12) * fadeOut(f, total)} />
);

// ---------------------------------------------------------------- 1. Yes, another browser.

export const FILM1 = 1080;
const T1 = { kept: 78, spaces: 150, peek: 282, split: 396, pip: 510, island: 640, dust: 770, hands: 870, end: 972 };

export const Film1: React.FC = () => {
  const frame = useCurrentFrame();
  const W = { x: 640, y: 168, width: 1180 };
  const slides = [
    { name: "f1-work", at: 0 },
    { name: "f1-personal", at: T1.spaces + 6 },
    { name: "f1-lisbon", at: T1.spaces + 52 },
    { name: "f1-work", at: T1.spaces + 98 },
    { name: "f1-peek", at: T1.peek },
    { name: "f1-split", at: T1.split },
    // Live takes (docs/launch-videos.md): the video lifting out, then its
    // chapters; the island rising, then opening; Clear's dust.
    { name: "pip-lift", at: T1.pip, take: "pip.mp4", from: 1.3 },
    { name: "pip-chapters", at: T1.pip + 62, take: "pip.mp4", from: 6.0 },
    { name: "island-rise", at: T1.island, take: "island.mp4", from: 1.2 },
    { name: "island-open", at: T1.island + 62, take: "island.mp4", from: 9.4 },
    { name: "dust", at: T1.dust, take: "dust.mp4", from: 5.5 },
    { name: "agent-tab", at: T1.hands, take: "agent.mp4", from: 4.4 },
  ];
  const windowOut = ramp(frame, T1.end - 12, 16);
  // A slow push on each beat, toward what the pen names: the space switcher,
  // the peeked page, the seam of the split, the island at the sidebar's foot.
  const beats: [number, number, [number, number]][] = [
    [0, T1.spaces, [0.55, 0.3]], [T1.spaces, T1.peek, [0.1, 0.95]], [T1.peek, T1.split, [0.65, 0.4]],
    [T1.split, T1.pip, [0.5, 0.45]], [T1.pip, T1.island, [0.82, 0.85]], [T1.island, T1.dust, [0.12, 0.9]],
    [T1.dust, T1.hands, [0.12, 0.45]], [T1.hands, T1.end, [0.15, 0.3]],
  ];
  const pushes: Push[] = beats.map(([start, end, at]) => ({ from: 1.0, to: 1.04, at, start, length: end - start, beat: [start, end] }));
  const notes: [number, string, number, string][] = [
    [T1.spaces + 10, "a space for each part of you", 520, "M 360 18 C 420 10, 470 30, 512 74"],
    [T1.peek + 8, "⇧-click any link", 400, "M 300 20 C 380 0, 440 40, 470 96"],
    [T1.split + 8, "any two, side by side", 380, "M 330 16 C 410 6, 450 40, 470 90"],
    [T1.pip + 8, "a video, out of its page", 700, "M 360 30 C 420 40, 470 40, 520 60"],
    [T1.island + 8, "what plays in other tabs", 860, "M 360 30 C 420 40, 470 20, 510 -20"],
    [T1.dust + 8, "and today's tabs, to dust", 420, "M 380 20 C 430 10, 470 30, 512 64"],
  ];
  return (
    <AbsoluteFill>
      <Fonts />
      <Paper />
      <Bed name="bed-1" total={FILM1} />
      <div style={{ opacity: 1 - windowOut }}>
        <Window slides={slides} {...W} enter={0} push={pushes} />
      </div>
      {/* 1: the promise, with the pen on "another" */}
      <Words at={0} x={110} y={300} size={96} out={T1.kept} text={<>Yes,<br />another<br />browser<span style={{ color: VIOLET }}>.</span></>} />
      {frame < T1.kept + 10 && (
        <Stroke at={22} length={16} box={[104, 478, 380, 40]} width={5} d="M 6 24 C 90 14, 200 30, 368 12" />
      )}
      {/* 2: for the people who miss Arc */}
      <Words at={T1.kept + 4} x={110} y={330} size={64} weight={600} out={T1.spaces - 8} text={<>You miss Arc.</>} />
      <Words at={T1.kept + 26} x={110} y={420} size={64} weight={600} out={T1.spaces - 8} text={<>So we kept<br />all of it.</>} />
      {/* 3 to 7: what was kept, each named by the pen */}
      {notes.map(([at, text, y, d], i) => {
        const next = notes[i + 1]?.[0] ?? T1.hands;
        if (frame < at || frame >= next) return null;
        return (
          <React.Fragment key={text}>
            <Hand text={text} at={at} x={96} y={y} size={50} />
            <Stroke at={at + 18} length={12} box={[96, y + 40, 540, 120]} d={d} width={3.5} />
          </React.Fragment>
        );
      })}
      {/* 8: and hands */}
      <Words at={T1.hands + 6} x={110} y={380} size={66} weight={650} out={T1.end - 10} text={<>Then we gave<br />it hands.</>} />
      {frame < T1.end - 6 && <Hand text="your Claude, in your tabs" at={T1.hands + 30} x={104} y={560} size={42} />}
      {frame >= T1.end - 4 && <Ending at={T1.end} />}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- 2. Then we gave it hands.

export const FILM2 = 966;
const T2 = { ask: 0, folder: 108, works: 190, yes: 270, mail: 426, thread: 570, page: 714, end: 846 };

const Line: React.FC<{ at: number; out: number; text: React.ReactNode; small?: React.ReactNode }> = ({ at, out, text, small }) => (
  <>
    <Words at={at} out={out} x={310} y={884} size={50} weight={600} color="#F2F2F2" text={text} />
    {small && <Words at={at + 8} out={out} x={312} y={950} size={28} weight={500} color="rgba(242,242,242,.55)" text={small} />}
  </>
);

export const Film2: React.FC = () => {
  const frame = useCurrentFrame();
  const slides = [
    { name: "f2-ask", at: 0 },
    // A real run of Claude (docs/launch-videos.md): Return, its chat in the
    // column; then its own tab, filtering for nonstop, the dock under it.
    { name: "agent-chat", at: T2.folder, take: "agent.mp4", from: 0.2 },
    { name: "agent-tab", at: T2.works - 6, take: "agent.mp4", from: 4.4 },
    { name: "f2-checkout", at: T2.yes },
    { name: "f2-mail", at: T2.mail }, { name: "f2-thread", at: T2.thread }, { name: "f2-page", at: T2.page },
  ];
  // A slow push into where each moment happens; the yes is pushed into,
  // after a beat to read the page, until the card reads.
  const beats: [number, number, [number, number], number][] = [
    [T2.ask, T2.folder, [0.5, 0.2], 1.035], [T2.folder, T2.yes, [0.55, 0.85], 1.035], [T2.yes, T2.mail, [0.5, 0.92], 1.45],
    [T2.mail, T2.thread, [0.45, 0.25], 1.035], [T2.thread, T2.page, [0.55, 0.45], 1.035], [T2.page, T2.end, [0.6, 0.4], 1.035],
  ];
  const pushes: Push[] = beats.map(([start, end, at, to]) => to > 1.1
    ? { from: 1.0, to, at, start: start + 30, length: 70, beat: [start, end] }
    : { from: 1.0, to, at, start, length: end - start, beat: [start, end] });
  const out = ramp(frame, T2.end - 14, 16);
  return (
    <AbsoluteFill style={{ background: "#0B0B0D" }}>
      <Fonts />
      <AbsoluteFill style={{ background: "radial-gradient(60% 50% at 50% 38%, rgba(154,107,255,.20), transparent 70%)" }} />
      <Paper dark />
      <Bed name="bed-2" total={FILM2} volume={0.75} />
      <div style={{ opacity: 1 - out }}>
        <Window dark slides={slides} x={310} y={40} width={1300} radius={20}
          push={pushes} overlays={[{ src: "shots/permit-pay.png", at: T2.yes + 24, x: 0.375, y: 0.885, w: 0.403 }]} />
      </div>
      <Line at={T2.ask + 8} out={T2.folder - 6} text="Ask for the trip, not the search." small="⌘T, then Task for Claude" />
      <Line at={T2.folder + 6} out={T2.works - 6} text="It works in tabs of its own." small="Its folder, its face, out of your way" />
      <Line at={T2.works + 4} out={T2.yes - 6} text="Clicks, types, reads. Like you would." small="Take over anytime, hand it back" />
      <Line at={T2.yes + 6} out={T2.mail - 6} text={<>Pay waits for <span style={{ color: VIOLET }}>your</span> yes.</>} small="Send, pay, delete: never without you" />
      <Line at={T2.mail + 6} out={T2.thread - 6} text="Your mail, sorted by what it wants." small="Needs you, Waiting, Other" />
      <Line at={T2.thread + 6} out={T2.page - 6} text="Replies written ahead, in your voice." small="Pick 1, 2 or 3, then ⌘↩" />
      <Line at={T2.page + 6} out={T2.end - 8} text="⌘J does what the page is for." small="Review the pull request, draft the reply" />
      {frame >= T2.end - 4 && (
        <>
          <Words at={T2.end} x={0} y={170} width={1920} size={40} weight={500} color="rgba(242,242,242,.7)"
            text={<div style={{ textAlign: "center" }}>Your Claude or ChatGPT. Your tabs. Your yes.</div>} />
          <Ending at={T2.end + 18} dark />
        </>
      )}
    </AbsoluteFill>
  );
};

// ---------------------------------------------------------------- 3. Fast. Like, really fast.

export const FILM3 = 972;
// A beat every 96 frames: the keys, then what they did (a still, or a live
// take from `from` seconds in, docs/launch-videos.md).
const beats: { at: number; keys: string[]; shot: string; words: string; take?: string; from?: number }[] = [
  { keys: ["⌘", "T"], shot: "f2-ask", words: "Everything starts in one field." },
  { keys: ["⌥", "↩"], shot: "f3-form", words: "A whole form, filled at once." },
  { keys: ["⇧", "⌘", "2"], shot: "capture", take: "capture.mp4", from: 8.8, words: "Any part of a page, as a picture." },
  { keys: ["⌥", "⌘", "U"], shot: "f3-measure", words: "Measure the page you're building." },
  { keys: ["⌥", "⌘", "I"], shot: "devtools", take: "devtools.mp4", from: 1.4, words: "Its errors, beside it." },
  { keys: ["⇧", "⌘", "P"], shot: "pip", take: "pip.mp4", from: 1.3, words: "A video in its own window." },
  { keys: ["⌥", "⌘", "L"], shot: "f3-passwords", words: "Passwords and codes, in your keychain." },
  { keys: ["⌃", "3"], shot: "f1-lisbon", words: "A space for each part of your life." },
].map((beat, i) => ({ ...beat, at: 84 + i * 96 }));

export const Film3: React.FC = () => {
  const frame = useCurrentFrame();
  const end = 84 + beats.length * 96;
  const beat = [...beats].reverse().find((b) => frame >= b.at);
  const mb = Math.round(interpolate(frame, [8, 46], [0, 33], { extrapolateLeft: "clamp", extrapolateRight: "clamp" }));
  const chrome = ramp(frame, 26, 40);
  return (
    <AbsoluteFill style={{ background: "#FFFFFF" }}>
      <Fonts />
      <Bed name="bed-3" total={FILM3} volume={0.85} />
      {/* 1: how small */}
      {frame < 84 && (
        <AbsoluteFill style={{ padding: "0 180px", justifyContent: "center", opacity: 1 - ramp(frame, 74, 10) }}>
          <div style={{ font: `600 36px ${SANS}`, color: "rgba(23,23,23,.5)", marginBottom: 34 }}>Size on disk</div>
          {[["Yab", 33, VIOLET, `${mb} MB`, 1], ["Chrome", 1434, "#D9D9DE", "1.4 GB", chrome]].map(([name, size, color, said, grow]) => (
            <div key={name as string} style={{ display: "flex", alignItems: "center", gap: 32, marginBottom: 26 }}>
              <div style={{ width: 210, font: `650 48px ${SANS}`, letterSpacing: "-0.02em", color: name === "Yab" ? INK : "rgba(23,23,23,.5)" }}>{name}</div>
              <div style={{ height: 52, width: Math.max(14, (1060 * (size as number)) / 1434) * (grow as number), borderRadius: 14, background: color as string }} />
              <div style={{ whiteSpace: "nowrap", font: `650 52px ${SANS}`, letterSpacing: "-0.03em", color: name === "Yab" ? INK : "rgba(23,23,23,.5)",
                opacity: name === "Yab" ? 1 : ramp(frame, 50, 12) }}>{said as string}</div>
            </div>
          ))}
        </AbsoluteFill>
      )}
      {/* 2 to 8: a key, then what it does */}
      {beat && frame < end && (() => {
        const local = frame - beat.at;
        const keyShown = beat.keys.length > 0 && local < 26;
        return (
          <>
            {keyShown && (
              <AbsoluteFill style={{ alignItems: "center", justifyContent: "center" }}>
                <Keys keys={beat.keys} at={beat.at} size={170} />
              </AbsoluteFill>
            )}
            {!keyShown && (
              <>
                <Window slides={[{ name: beat.shot, at: beat.at + (beat.keys.length ? 26 : 0), take: beat.take, from: beat.from }]} x={250} y={90} width={1420} radius={18}
                  enter={beat.at + (beat.keys.length ? 26 : 0)} push={{ from: 1.0, to: 1.04, at: [0.5, 0.5], start: beat.at + 26, length: 58 }} />
                <Words at={beat.at + (beat.keys.length ? 30 : 4)} x={0} y={990} width={1920} size={40} weight={600}
                  text={<div style={{ textAlign: "center" }}>{beat.words}</div>} />
              </>
            )}
          </>
        );
      })()}
      {frame >= end - 4 && <Ending at={end} line="Fast. Like, really fast." />}
    </AbsoluteFill>
  );
};
