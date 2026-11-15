#!/usr/bin/env python3
"""Drift's music and covers, made on this Mac from arithmetic alone.

    python3 make_audio.py [CACHE] [--only ID,ID] [--force]
        the six tracks as AAC in .m4a (WAV when there is no ffmpeg) in CACHE,
        ~/Library/Caches/yab-demo/drift by default; tracks already there are
        skipped, and all are made again when VERSION changes
    python3 make_audio.py --covers
        every cover (SVG, and for each track a 512 PNG for MediaSession) and
        the site's icons, into this folder

Nothing here is a recording, so a demo video never carries anyone's
copyrighted audio: soft pads (PADsynth: a chord's spectrum, given random
phases, turned into sound by one inverse FFT), a plucked arpeggio or an
electric piano, a bass, a brushed beat on some, a little vinyl, rain or sea.

Each track is a loop: whatever still rings at its end (an echo, the reverb,
a chord fading) is folded back onto its start, so it plays round without a
seam. With numpy all six take a few seconds; without it a plainer pure
Python engine plays the same score, slower and simpler.
"""
import argparse
import math
import os
import random
import shutil
import subprocess
import sys
import tempfile
import time
import wave
from array import array
from pathlib import Path

HERE = Path(__file__).resolve().parent
CACHE = Path.home() / "Library" / "Caches" / "yab-demo" / "drift"
VERSION = "1"
SR = 44100        # the numpy engine: 44.1 kHz stereo
PLAIN_SR = 22050  # the pure Python one: 22.05 kHz mono, widened by ffmpeg

# ---------------------------------------------------------------- the music

TRACKS = [
    dict(
        id="paper-lanterns", title="Paper Lanterns", artist="Maren Holt",
        bpm=64, cycles=4, seed=11, swing=0.0,
        chords=["D3 A3 C#4 E4 F#4", "B2 F#3 A3 D4 E4", "G2 D3 F#3 A3 B3", "A2 E3 G3 B3 D4"],
        bass=dict(roots=["D2", "B1", "G1", "A1"], style="long", level=0.56),
        pad=dict(level=0.30, bw=26, dark=1800, bright=5200, morph=(0.15, 0.7), verb=0.2),
        keys=[dict(kind="kalimba", style="arp8", octave=12, level=1.18, pattern=[0, 2, 4, 3, 1, 3, 2, 4], rest=0.12, pan=0.35)],
        bell=dict(level=0.75, scale="D E F# A B", octave=12, density=0.4),
        drums=None,
        textures=dict(vinyl=0.87, hiss=0.9),
        echo=dict(beats=0.75, feedback=0.42, mix=0.5, verb=0.45),
        verb=dict(wet=0.30, decay=(1.2, 0.85, 0.35)),
        plan=dict(pad=[0.85, 1.0, 1.0, 0.9], keys0=[0.5, 1.0, 1.0, 0.6], bass=[0.45, 0.9, 1.0, 0.6], bell=[0.0, 0.8, 1.0, 0.0]),
    ),
    dict(
        id="cedar-and-salt", title="Cedar and Salt", artist="The Lindens",
        bpm=82, cycles=5, seed=23, swing=0.07,
        chords=["C3 G3 B3 D4 E4", "B2 F#3 A3 D4 E4", "E3 B3 D4 F#4 G4", "D3 A3 B3 E4 F#4"],
        bass=dict(roots=["C2", "B1", "E2", "D2"], style="pulse", level=0.74),
        pad=dict(level=0.24, bw=22, dark=2000, bright=4800, morph=(0.2, 0.65), verb=0.15),
        keys=[dict(kind="epiano", style="comp", octave=0, level=0.50, pan=0.15),
              dict(kind="harp", style="arp8", octave=12, level=0.43, pattern=[0, 1, 2, 3, 4, 2, 3, 1], rest=0.35, pan=0.45)],
        bell=None,
        drums=dict(style="brush", level=1.05),
        textures=dict(vinyl=0.7, hiss=0.7),
        echo=dict(beats=0.75, feedback=0.35, mix=0.4, verb=0.35),
        verb=dict(wet=0.24, decay=(0.9, 0.65, 0.3)),
        plan=dict(pad=[0.8, 0.9, 1.0, 0.95, 0.8], keys0=[0.5, 1.0, 1.0, 1.0, 0.6], keys1=[0.0, 0.5, 0.9, 0.7, 0.2],
                  bass=[0.3, 1.0, 1.0, 1.0, 0.5], drums=[0.0, 0.75, 1.0, 1.0, 0.3]),
    ),
    dict(
        id="linen-hours", title="Linen Hours", artist="Odette Vale",
        bpm=60, cycles=4, seed=37, swing=0.0,
        chords=["F3 A3 C4 E4 G4", "A2 E3 G3 C4 D4", "D3 F3 A3 C4 E4", "Bb2 F3 A3 D4 E4"],
        bass=dict(roots=["F2", "A1", "D2", "Bb1"], style="long", level=0.58),
        pad=dict(level=0.30, bw=30, dark=1600, bright=4200, morph=(0.15, 0.7), verb=0.22),
        keys=[dict(kind="harp", style="roll", octave=12, level=2.55, pan=0.5)],
        bell=dict(level=1.1, scale="F G A C D", octave=12, density=0.45),
        drums=None,
        textures=dict(rain=1.0, hiss=0.4),
        echo=dict(beats=1.5, feedback=0.4, mix=0.45, verb=0.5),
        verb=dict(wet=0.34, decay=(1.4, 1.0, 0.4)),
        plan=dict(pad=[0.9, 1.0, 1.0, 0.9], keys0=[0.6, 1.0, 1.0, 0.7], bass=[0.3, 0.8, 0.9, 0.5], bell=[0.0, 0.9, 1.0, 0.2]),
    ),
    dict(
        id="low-tide", title="Low Tide", artist="Harbor Club",
        bpm=76, cycles=5, seed=41, swing=0.09,
        chords=["A2 E3 G3 B3 C4", "D3 F3 A3 C4 E4", "G2 D3 E3 A3 B3", "C3 G3 B3 D4 E4"],
        bass=dict(roots=["A1", "D2", "G1", "C2"], style="pulse", level=0.67),
        pad=dict(level=0.22, bw=20, dark=1700, bright=4000, morph=(0.2, 0.6), verb=0.15),
        keys=[dict(kind="epiano", style="comp", octave=0, level=0.45, pan=0.12)],
        bell=dict(level=1.2, scale="A C D E G", octave=12, density=0.3),
        drums=dict(style="lofi", level=0.82),
        textures=dict(sea=0.88, vinyl=0.25),
        echo=dict(beats=0.75, feedback=0.38, mix=0.4, verb=0.4),
        verb=dict(wet=0.24, decay=(0.9, 0.65, 0.28)),
        plan=dict(pad=[0.8, 0.9, 1.0, 0.9, 0.8], keys0=[0.6, 1.0, 1.0, 1.0, 0.7], bell=[0.0, 0.5, 0.9, 0.6, 0.0],
                  bass=[0.3, 1.0, 1.0, 1.0, 0.5], drums=[0.0, 1.0, 1.0, 1.0, 0.35]),
    ),
    dict(
        id="night-ferry", title="Night Ferry", artist="Lumen Kid",
        bpm=84, cycles=5, seed=53, swing=0.0,
        chords=["E3 B3 D4 F#4 G4", "A2 E3 G3 B3 C#4", "C3 G3 B3 D4 E4", "B2 F#3 A3 D4 E4"],
        bass=dict(roots=["E2", "A1", "C2", "B1"], style="pulse", level=0.71),
        pad=dict(level=0.22, bw=18, dark=2200, bright=5200, morph=(0.2, 0.7), verb=0.15),
        keys=[dict(kind="pluck", style="arp16", octave=12, level=1.26, pattern=[0, 2, 1, 3, 2, 4, 3, 1], rest=0.08, pan=0.3)],
        bell=None,
        drums=dict(style="ferry", level=0.87),
        textures=dict(vinyl=0.52, hiss=0.65),
        echo=dict(beats=0.75, feedback=0.45, mix=0.45, verb=0.35),
        verb=dict(wet=0.26, decay=(1.0, 0.7, 0.3)),
        plan=dict(pad=[0.9, 0.9, 1.0, 1.0, 0.9], keys0=[0.5, 1.0, 1.0, 1.0, 0.6], bass=[0.3, 1.0, 1.0, 1.0, 0.4],
                  drums=[0.0, 0.8, 1.0, 1.0, 0.3]),
    ),
    dict(
        id="moon-pool", title="Moon Pool", artist="Small Hours",
        bpm=66, cycles=4, seed=67, swing=0.0,
        chords=["Db3 Ab3 C4 Eb4 F4", "Bb2 F3 Ab3 C4 Db4", "Gb2 Db3 F3 Ab3 Bb3", "Ab2 Eb3 Gb3 Bb3 Db4"],
        bass=dict(roots=["Db2", "Bb1", "Gb1", "Ab1"], style="long", level=0.52),
        pad=dict(level=0.30, bw=34, dark=1500, bright=4400, morph=(0.15, 0.7), verb=0.22),
        keys=[dict(kind="harp", style="arp8", octave=12, level=1.88, pattern=[0, 2, 4, 2, 1, 3, 4, 3], rest=0.2, pan=0.45)],
        bell=dict(level=1.18, scale="Db Eb F Ab Bb", octave=12, density=0.35),
        drums=dict(style="pulse", level=1.08),
        textures=dict(drips=1.2, hiss=0.8),
        echo=dict(beats=1.0, feedback=0.45, mix=0.5, verb=0.5),
        verb=dict(wet=0.34, decay=(1.5, 1.05, 0.4)),
        plan=dict(pad=[0.9, 1.0, 1.0, 0.9], keys0=[0.4, 0.9, 1.0, 0.5], bell=[0.0, 0.8, 1.0, 0.3],
                  bass=[0.4, 0.9, 1.0, 0.5], drums=[0.0, 0.8, 1.0, 0.0]),
    ),
]
IDS = [t["id"] for t in TRACKS]
BY_ID = {t["id"]: t for t in TRACKS}

# How long each kind of note rings, seconds, and each drum's level.
RING = dict(kalimba=1.8, harp=2.2, epiano=1.6, pluck=1.2, bell=3.2)
KIT = dict(kick=1.24, snare=0.60, rim=0.28, hat=0.16, swish=0.22)

DRUMS = {
    "brush": dict(kick=[(0, 1.0), (2.5, 0.7)], snare=[(1, 0.8), (3, 0.9)],
                  ghost=[(1.75, 0.22, 0.3), (3.5, 0.2, 0.25)], hats=(0.5, (0.42, 0.26)), swish=0.55, rim=0.0),
    "lofi": dict(kick=[(0, 1.0), (0.75, 0.55, 0.5), (2.5, 0.85)], snare=[(1, 0.85), (3, 0.95)],
                 ghost=[(3.75, 0.25, 0.35)], hats=(0.5, (0.5, 0.3)), swish=0.0, rim=0.35),
    "ferry": dict(kick=[(0, 1.0), (1.5, 0.75), (2.75, 0.6, 0.6)], snare=[(1, 0.8), (3, 0.85)],
                  ghost=[], hats=(0.25, (0.36, 0.16, 0.26, 0.16)), swish=0.0, rim=0.3),
    "pulse": dict(kick=[(0, 0.85), (2, 0.55)], snare=[(3, 0.3)], ghost=[], hats=None, swish=0.7, rim=0.0),
}

STEPS = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def midi(name):
    """'C#4' or 'Bb2' as a MIDI note number."""
    i, shift = 1, 0
    while name[i] in "#b":
        shift += 1 if name[i] == "#" else -1
        i += 1
    return 12 * (int(name[i:]) + 1) + STEPS[name[0]] + shift


def hz(note):
    return 440.0 * 2.0 ** ((note - 69) / 12.0)


def pan(position):
    """Equal-power gains for a place between -1 (left) and 1 (right)."""
    angle = (max(-1.0, min(1.0, position)) + 1.0) * math.pi / 4.0
    return math.cos(angle), math.sin(angle)


def seconds(spec):
    """The track's length: its beats at its tempo, to the sample."""
    beats = len(spec["chords"]) * 8 * spec["cycles"]
    return round(beats * 60.0 / spec["bpm"] * SR) / SR


class Score:
    """When everything in a track sounds, in beats. Both engines play it."""

    def __init__(self, spec):
        self.spec = spec
        self.chords = [[midi(n) for n in c.split()] for c in spec["chords"]]
        self.chord_beats = 8
        self.cycle_beats = self.chord_beats * len(self.chords)
        self.beats = self.cycle_beats * spec["cycles"]

    def rng(self, part):
        return random.Random("%s:%s" % (self.spec["seed"], part))

    def chord(self, beat):
        return self.chords[int(beat // self.chord_beats) % len(self.chords)]

    def level(self, part, beat):
        """A part's level in the arrangement: each cycle has its own, eased
        into the next over the cycle's last bar, the last into the first."""
        plan = self.spec.get("plan", {}).get(part)
        if not plan:
            return 1.0
        place = (beat % self.beats) / self.cycle_beats
        k = int(place)
        here, after = plan[k % len(plan)], plan[(k + 1) % len(plan)]
        edge = 1.0 - 4.0 / self.cycle_beats
        x = (place - k - edge) / (1.0 - edge)
        if x <= 0:
            return here
        return here + (after - here) * (0.5 - 0.5 * math.cos(math.pi * min(1.0, x)))

    def keys(self, layer, part):
        """(beat, note, gain, pan) for an arpeggio, a comping piano or a harp."""
        rng = self.rng(part)
        style, octave, width = layer["style"], layer.get("octave", 0), layer.get("pan", 0.3)
        swing = self.spec.get("swing", 0.0)
        out = []

        def put(beat, note, vel, place):
            gain = layer["level"] * vel * self.level(part, beat)
            if gain > 0.003:
                out.append((beat, note, gain, place))

        if style in ("arp8", "arp16"):
            step = 0.5 if style == "arp8" else 0.25
            pattern = layer["pattern"]
            per_bar = int(4 / step)
            for i in range(int(self.beats / step)):
                beat = i * step
                if beat % 4 and rng.random() < layer.get("rest", 0.1):
                    continue
                pool = sorted(set(self.chord(beat)[1:]))
                j = pattern[(i + (2 if (i // per_bar) % 2 else 0)) % len(pattern)]
                note = pool[j % len(pool)] + 12 * (j // len(pool)) + octave
                accent = 1.0 if beat % 4 == 0 else 0.8 if beat % 1 == 0 else 0.62
                at = beat + (swing if step == 0.5 and i % 2 else 0.0) + rng.gauss(0, 0.008)
                put(at, note, accent * (0.85 + 0.25 * rng.random()), rng.uniform(-width, width))
        elif style == "comp":
            figures = [[0.0, 1.5, 3.0], [0.5, 2.0, 2.75], [0.0, 1.5, 2.5, 3.25], [0.5, 2.0, 3.0]]
            strum = 0.011 * self.spec["bpm"] / 60.0
            for bar in range(self.beats // 4):
                for hit in figures[bar % len(figures)]:
                    if hit and rng.random() < 0.08:
                        continue
                    beat = bar * 4 + hit
                    start = beat + (swing if hit % 1 == 0.5 else 0.0)
                    voicing = sorted(self.chord(beat)[1:])[-4:]
                    vel = (0.95 if hit == 0 else 0.72) * (0.85 + 0.2 * rng.random())
                    for j, note in enumerate(voicing):
                        put(start + j * strum + rng.gauss(0, 0.004), note + octave, vel * (0.9 + 0.1 * j / 3),
                            rng.uniform(-width, width))
        elif style == "roll":
            for slot in range(self.beats // self.chord_beats):
                base = slot * self.chord_beats
                pool = sorted(set(self.chord(base)[1:]))
                rising = [n + octave for n in pool] + [pool[0] + octave + 12, pool[1] + octave + 12]
                for j, note in enumerate(rising):
                    put(base + j * 0.25 + rng.gauss(0, 0.01), note, 0.5 + 0.07 * j,
                        -width + 2 * width * j / (len(rising) - 1))
                for j, at in enumerate((4.5, 5.5, 6.5)):
                    if rng.random() < 0.85:
                        put(base + at + rng.gauss(0, 0.01), rising[len(rising) - 2 - j], 0.42, rng.uniform(-width, width))
        return out

    def bell(self):
        """A few quiet notes of a melody, walking the scale, on chord tones at the bar."""
        b = self.spec.get("bell")
        if not b:
            return []
        rng = self.rng("bell")
        classes = {midi(name + "4") % 12 for name in b["scale"].split()}
        low = 60 + b.get("octave", 12)
        ladder = [n for n in range(low, low + 15) if n % 12 in classes]
        where = len(ladder) // 2
        rhythms = [[0.0, 1.5], [0.5, 2.0, 3.0], [0.0], [1.0, 2.5], [0.0, 2.0, 3.5]]
        out = []
        for bar in range(self.beats // 4):
            if rng.random() > b["density"]:
                continue
            for hit in rng.choice(rhythms):
                beat = bar * 4 + hit
                where = max(0, min(len(ladder) - 1, where + rng.choice((-2, -1, -1, 0, 1, 1, 2))))
                if hit == 0:
                    tones = {n % 12 for n in self.chord(beat)}
                    near = [p for p in range(max(0, where - 1), min(len(ladder), where + 2)) if ladder[p] % 12 in tones]
                    if near:
                        where = near[0]
                gain = b["level"] * (0.7 + 0.3 * rng.random()) * self.level("bell", beat)
                if gain > 0.003:
                    out.append((beat + rng.gauss(0, 0.01), ladder[where], gain, rng.uniform(-0.4, 0.4)))
        return out

    def bass(self):
        """(beat, note, gain, beats long)."""
        b = self.spec.get("bass")
        if not b:
            return []
        rng = self.rng("bass")
        roots = [midi(r) for r in b["roots"]]
        out = []
        for slot in range(self.beats // self.chord_beats):
            base = slot * self.chord_beats
            root, following = roots[slot % len(roots)], roots[(slot + 1) % len(roots)]
            if b["style"] == "long":
                hits = [(0.0, root, self.chord_beats - 0.25, 1.0)]
            else:
                hits = [(0.0, root, 1.4, 1.0), (2.5, root, 1.1, 0.8), (4.0, root, 1.4, 0.95), (6.5, root, 0.9, 0.75)]
                if rng.random() < 0.5:
                    hits.append((7.5, following, 0.45, 0.6))
            for at, note, size, vel in hits:
                gain = b["level"] * vel * self.level("bass", base + at)
                if gain > 0.003:
                    out.append((base + at, note, gain, size))
        return out

    def drums(self):
        """(beat, drum, gain, pan)."""
        d = self.spec.get("drums")
        if not d:
            return []
        p = DRUMS[d["style"]]
        rng = self.rng("drums")
        swing = self.spec.get("swing", 0.0)
        out = []

        def put(beat, name, vel, place=0.0, jitter=0.006):
            gain = d["level"] * vel * KIT[name] * self.level("drums", beat)
            if gain > 0.002:
                out.append((beat + rng.gauss(0, jitter), name, gain * (0.9 + 0.2 * rng.random()), place))

        for bar in range(self.beats // 4):
            b0 = bar * 4
            for hit in p["kick"]:
                if len(hit) > 2 and rng.random() > hit[2]:
                    continue
                put(b0 + hit[0], "kick", hit[1])
            for at, vel in p["snare"]:
                put(b0 + at, "snare", vel, 0.08)
                if p["rim"]:
                    put(b0 + at, "rim", p["rim"] * vel / 0.35, 0.1)
            for at, vel, chance in p["ghost"]:
                if rng.random() < chance:
                    put(b0 + at, "snare", vel, 0.08)
            if p["hats"]:
                step, vels = p["hats"]
                for i in range(int(4 / step)):
                    late = swing if step == 0.5 and i % 2 else 0.0
                    put(b0 + i * step + late, "hat", vels[i % len(vels)] / 0.5, -0.2)
            if p["swish"]:
                for beat in range(4):
                    put(b0 + beat, "swish", p["swish"], 0.25 if beat % 2 else -0.25, 0.0)
        return out


# ---------------------------------------------------------------- with numpy

def render(spec, stats=False):
    """One track as int16 stereo frames, a seamless loop."""
    import numpy as np

    score = Score(spec)
    spb = 60.0 / spec["bpm"] * SR
    n = int(round(score.beats * spb))
    rng = np.random.default_rng(spec["seed"])
    buses = {name: np.zeros((2, n), np.float32) for name in ("dry", "echo", "verb")}

    def at(beat):
        return int(round(beat * spb))

    def add(name, left, right, start):
        """Into a bus, wrapping round the end: the track is a loop."""
        buf, size, pos, done = buses[name], len(left), start % n, 0
        while done < size:
            take = min(size - done, n - pos)
            buf[0, pos:pos + take] += left[done:done + take]
            buf[1, pos:pos + take] += right[done:done + take]
            done += take
            pos = 0

    def note(beat, sound, gain, place, bus="dry"):
        left, right = pan(place)
        add(bus, sound * (gain * left), sound * (gain * right), at(beat))

    def levels(part, idx):
        return np.array([score.level(part, b) for b in idx / spb]) if spec.get("plan", {}).get(part) else np.ones(len(idx))

    # Pads: two textures a chord, one darker, one brighter, crossfaded slowly
    # as if a filter opened and closed once a cycle; chords meet over two beats.
    pad = spec["pad"]
    textures = [(padsynth(np, c, rng, pad["bw"], pad["dark"]), padsynth(np, c, rng, pad["bw"] * 1.2, pad["bright"]))
                for c in score.chords]
    span = textures[0][0][0].shape[0]
    half = int(spb)
    ramp = np.sin(0.5 * np.pi * (np.arange(2 * half) + 0.5) / (2 * half))
    for slot in range(score.beats // score.chord_beats):
        (dl, dr), (bl, br) = textures[slot % len(score.chords)]
        start, end = at(slot * score.chord_beats) - half, at((slot + 1) * score.chord_beats) + half
        size = end - start
        idx = np.arange(start, end) % n
        window = np.ones(size)
        window[:2 * half] = ramp
        window[-2 * half:] = ramp[::-1]
        # Control rate: the arrangement's level every 512 samples is plenty.
        coarse = idx[::512]
        level = np.interp(np.arange(size), np.arange(0, size, 512), levels("pad", coarse)) * pad["level"] * window
        lo, hi = pad["morph"]
        morph = lo + (hi - lo) * (0.5 - 0.5 * np.cos(2 * np.pi * idx * spec["cycles"] / n))
        dark, bright = np.cos(0.5 * np.pi * morph) * level, np.sin(0.5 * np.pi * morph) * level
        ti = (int(rng.integers(0, span)) + np.arange(size)) % span
        left = dl[ti] * dark + bl[ti] * bright
        right = dr[ti] * dark + br[ti] * bright
        add("dry", left, right, start)
        add("verb", left * pad["verb"], right * pad["verb"], start)

    # Bass.
    for beat, pitch, gain, size in score.bass():
        sound = bass_np(np, pitch, size * spb / SR, spec["bass"]["style"])
        note(beat, sound, gain, 0.0)

    # Drums, a little of them into the room.
    if spec.get("drums"):
        kit = kit_np(np, rng, spb)
        for beat, name, gain, place in score.drums():
            note(beat, kit[name], gain, place)
            note(beat, kit[name], gain * 0.18, place, "verb")

    # Keys and bell go through the echo.
    for i, layer in enumerate(spec.get("keys", [])):
        made = {}
        for beat, pitch, gain, place in score.keys(layer, "keys%d" % i):
            if pitch not in made:
                made[pitch] = tone_np(np, layer["kind"], pitch)
            note(beat, made[pitch], gain, place, "echo")
    made = {}
    for beat, pitch, gain, place in score.bell():
        if pitch not in made:
            made[pitch] = tone_np(np, "bell", pitch)
        note(beat, made[pitch], gain, place, "echo")

    # Echo: ping-pong taps of a darker copy, each round trip a little darker.
    e = spec["echo"]
    delay = at(e["beats"])
    echo = buses["echo"]
    darker = smooth_np(np, 0.5 * (echo[0] + echo[1]), 7)
    out = echo.copy()
    gain = e["mix"]
    for k in range(1, 6):
        out[k % 2] += np.roll(darker, delay * k) * gain
        gain *= e["feedback"]
        if k % 2 == 0:
            darker = smooth_np(np, darker, 5)
    buses["dry"] += out
    buses["verb"] += out * e["verb"]
    del out, darker

    # Texture.
    tx = spec.get("textures", {})
    dry = buses["dry"]
    if "hiss" in tx:
        for c in range(2):
            dry[c] += np.resize(noise_loop(np, rng, 1 << 17, 180, 7500, 0.6), n) * (0.02 * tx["hiss"])
    if "vinyl" in tx:
        crackle = crackle_np(np, rng, n)
        dry[0] += crackle * (0.15 * tx["vinyl"])
        dry[1] += np.roll(crackle, 41) * (0.135 * tx["vinyl"])
    if "rain" in tx:
        for c in range(2):
            drops = drops_np(np, rng, n, 70)
            bed = np.resize(noise_loop(np, rng, 1 << 18, 300, 6000, 1.0), n)
            swell = 0.6 + 0.4 * np.sin(2 * np.pi * np.arange(n) * 3 / n + c * 1.3)
            dry[c] += (drops * 0.15 + bed * 0.036 * swell) * tx["rain"]
    if "sea" in tx:
        waves = max(1, round(n / SR / 9.5))
        for c in range(2):
            bed = np.resize(noise_loop(np, rng, 1 << 18, 60, 1100, 1.0), n)
            swell = 0.25 + 0.75 * (0.5 - 0.5 * np.cos(2 * np.pi * np.arange(n) * waves / n + c * 0.7)) ** 1.6
            dry[c] += bed * swell * (0.045 * tx["sea"])
    if "drips" in tx:
        count = int(n / SR * 0.32)
        t = np.arange(int(0.2 * SR)) / SR
        for _ in range(count):
            f0 = rng.uniform(700, 1500)
            sweep = f0 * (1 + 0.9 * (1 - np.exp(-t / 0.01)))
            drip = np.sin(2 * np.pi * np.cumsum(sweep) / SR) * np.exp(-t / 0.045) * (1 - np.exp(-t / 0.001))
            start, gain, place = int(rng.integers(0, n)), rng.uniform(0.3, 1.0) * 0.25 * tx["drips"], rng.uniform(-0.7, 0.7)
            left, right = pan(place)
            add("dry", drip * gain * left, drip * gain * right, start)
            add("verb", drip * gain * left * 2.5, drip * gain * right * 2.5, start)

    # The room: a made-up impulse, lows ringing longest, folded round the loop.
    v = spec["verb"]
    room = impulse_np(np, rng, 2.8, v["decay"])
    for c in range(2):
        dry[c] += (circular_np(np, buses["verb"][c].astype(np.float64), room[c]) * v["wet"]).astype(np.float32)

    if stats:
        for name, buf in buses.items():
            print("  %-5s rms %.4f" % (name, float(np.sqrt(np.mean(buf.astype(np.float64) ** 2)))), file=sys.stderr)
    return master_np(np, dry)


def padsynth(np, chord, rng, bw, cut, size=1 << 18):
    """A chord as a perfectly looping stereo texture: every harmonic of every
    note a Gaussian band of the spectrum (wider up high), random phases, one
    inverse FFT a channel. Unit RMS."""
    half = size // 2 + 1
    amp = np.zeros(half)
    per_bin = SR / size
    for m in chord:
        f0 = hz(m)
        for h in range(1, 33):
            f = f0 * h
            a = h ** -1.1 * math.exp(-f / cut)
            if f > 12000 or a < 2e-4:
                break
            width = max((2 ** (bw / 1200.0) - 1) * f0 * h ** 0.85 / per_bin, 1.5)
            center = f / per_bin
            lo, hi = max(1, int(center - 4 * width)), min(half, int(center + 4 * width) + 2)
            x = (np.arange(lo, hi) - center) / width
            amp[lo:hi] += a * np.exp(-x * x) / math.sqrt(width)
    out = [np.fft.irfft(amp * np.exp(2j * np.pi * rng.random(half)), size) for _ in range(2)]
    scale = 1.0 / max(float(np.sqrt(np.mean(out[0] ** 2))), 1e-9)
    return out[0] * scale, out[1] * scale


def tone_np(np, kind, m):
    """One note, peak 1: a kalimba, a harp, an electric piano, a soft synth pluck or a bell."""
    f = hz(m)
    t = np.arange(int(RING[kind] * SR)) / SR
    w = 2 * np.pi * f * t
    if kind == "kalimba":
        y = (np.sin(w) * np.exp(-t * 2.4) + 0.30 * np.sin(2 * w) * np.exp(-t * 6.0)
             + 0.14 * np.sin(3.0 * w + 1.0) * np.exp(-t * 11.0) + 0.07 * np.sin(5.95 * w) * np.exp(-t * 26.0))
        attack = 0.002
    elif kind == "harp":
        y = sum(0.85 ** h / h ** 0.6 * np.sin(h * w * (1 + 0.0002 * h * h)) * np.exp(-t * (1.6 + 1.3 * h)) for h in range(1, 8))
        attack = 0.004
    elif kind == "epiano":
        index = 1.25 * np.exp(-t / 0.3) + 0.18
        y = np.sin(w + index * np.sin(w)) * np.exp(-t * 1.3) + 0.08 * np.sin(4 * w) * np.exp(-t * 12.0)
        attack = 0.003
    elif kind == "pluck":
        y = sum(np.sin(h * w) / h * np.exp(-t * (3.5 + 5.0 * h)) for h in range(1, 9))
        attack = 0.002
    else:
        y = (np.sin(w) * np.exp(-t * 0.9) + 0.35 * np.sin(2 * w) * np.exp(-t * 1.7)
             + 0.18 * np.sin(3 * w) * np.exp(-t * 3.2) + 0.08 * np.sin(4.16 * w) * np.exp(-t * 6.0))
        attack = 0.006
    y = y * (1 - np.exp(-t / attack))
    fade = int(0.05 * SR)
    y[-fade:] *= np.linspace(1, 0, fade)
    return (y / np.max(np.abs(y))).astype(np.float32)


def bass_np(np, m, length, style):
    t = np.arange(max(1, int(length * SR))) / SR
    w = 2 * np.pi * hz(m) * t
    y = np.sin(w) + 0.22 * np.sin(2 * w) + 0.06 * np.sin(3 * w)
    if style == "long":
        env = (1 - np.exp(-t / 0.08)) * (0.8 + 0.2 * np.exp(-t / 1.5))
        tail = min(len(t), int(0.45 * SR))
    else:
        env = (1 - np.exp(-t / 0.008)) * (0.55 + 0.45 * np.exp(-t / 0.35))
        tail = min(len(t), int(0.07 * SR))
    env[-tail:] *= np.cos(0.5 * np.pi * np.linspace(0, 1, tail))
    return (y * env / 1.25).astype(np.float32)


def band_np(np, x, low, high):
    spec = np.fft.rfft(x)
    f = np.maximum(np.fft.rfftfreq(len(x), 1.0 / SR), 1.0)
    return np.fft.irfft(spec / (1.0 + (low / f) ** 4) / (1.0 + (f / high) ** 4), len(x))


def kit_np(np, rng, spb):
    """A soft kit: a round kick, brushes on the snare, a rim, a closed hat, a brush swish a beat long."""
    def peak(y, top=1.0):
        return (y / np.max(np.abs(y)) * top).astype(np.float32)

    kit = {}
    t = np.arange(int(0.45 * SR)) / SR
    body = np.sin(2 * np.pi * np.cumsum(46.0 + 70.0 * np.exp(-t / 0.03)) / SR) * np.exp(-t / 0.17)
    click = band_np(np, rng.standard_normal(len(t)) * np.exp(-t / 0.0015), 300, 3000) * 0.5
    kit["kick"] = peak(np.tanh(1.6 * (body + click)))
    t = np.arange(int(0.6 * SR)) / SR
    kit["snare"] = peak(band_np(np, rng.standard_normal(len(t)), 900, 8000)
                        * (1 - np.exp(-t / 0.005)) * (0.65 * np.exp(-t / 0.075) + 0.35 * np.exp(-t / 0.28)))
    t = np.arange(int(0.12 * SR)) / SR
    kit["rim"] = peak(0.6 * np.sin(2 * np.pi * 1700 * t) * np.exp(-t / 0.012)
                      + 0.5 * band_np(np, rng.standard_normal(len(t)), 2000, 9000) * np.exp(-t / 0.006))
    t = np.arange(int(0.14 * SR)) / SR
    kit["hat"] = peak(band_np(np, rng.standard_normal(len(t)), 6500, 15000) * np.exp(-t / 0.03))
    t = np.arange(int(spb)) / SR
    kit["swish"] = peak(band_np(np, rng.standard_normal(len(t)), 1200, 7000) * np.sin(np.pi * t / t[-1]) ** 1.5)
    return kit


def smooth_np(np, x, k):
    return np.convolve(x, np.ones(k, np.float32) / k, mode="same").astype(np.float32)


def noise_loop(np, rng, size, low, high, tilt):
    """Shaped noise that loops in `size` samples, unit RMS."""
    spec = np.fft.rfft(rng.standard_normal(size))
    f = np.maximum(np.fft.rfftfreq(size, 1.0 / SR), 1.0)
    y = np.fft.irfft(spec / (1.0 + (low / f) ** 4) / (1.0 + (f / high) ** 4) * (f / 1000.0) ** (-tilt / 2), size)
    return (y / np.sqrt(np.mean(y ** 2))).astype(np.float32)


def crackle_np(np, rng, n):
    """Vinyl: tiny clicks, now and then a softer pop. Peak 1."""
    out = np.zeros(n, np.float32)
    for rate, sizes, top in ((7.0, (4, 24), 1.0), (0.25, (60, 200), 2.5)):
        for _ in range(int(n / SR * rate)):
            size = int(rng.integers(*sizes))
            p = int(rng.integers(0, n - size))
            burst = rng.standard_normal(size) * np.exp(-np.arange(size) / max(size / 3.0, 1.0))
            out[p:p + size] += burst * min(rng.exponential(1.0), 4.0) * top
    out = np.diff(out, prepend=out[-1])
    return out / max(float(np.max(np.abs(out))), 1e-9)


def drops_np(np, rng, n, rate):
    """Rain on a window: many small bright ticks."""
    out = np.zeros(n, np.float32)
    for _ in range(int(n / SR * rate)):
        size = int(rng.integers(30, 120))
        p = int(rng.integers(0, n - size))
        out[p:p + size] += rng.standard_normal(size) * np.exp(-np.arange(size) / (size / 4.0)) * rng.lognormal(-1.0, 0.6)
    out = np.diff(out, prepend=out[-1])
    return out / max(float(np.max(np.abs(out))), 1e-9)


def impulse_np(np, rng, length, decay):
    """A room for each ear: noise in three bands dying away at their own pace,
    after 15 ms; unit energy."""
    n = int(length * SR)
    t = np.arange(n) / SR
    f = np.fft.rfftfreq(n, 1.0 / SR)
    low = 1.0 / (1.0 + (f / 500.0) ** 2)
    high = (f / 4000.0) ** 2 / (1.0 + (f / 4000.0) ** 2)
    bands = (low, np.clip(1.0 - low - high, 0, None), high)
    out = []
    for _ in range(2):
        spec = np.fft.rfft(rng.standard_normal(n))
        y = sum(np.fft.irfft(spec * band, n) * np.exp(-t / tau) for band, tau in zip(bands, decay))
        pre = int(0.015 * SR)
        y = np.concatenate([np.zeros(pre), y[:-pre]])
        fade = int(0.01 * SR)
        y[pre:pre + fade] *= np.linspace(0, 1, fade)
        out.append(y / np.sqrt(np.sum(y ** 2)))
    return out


def fast_length(m):
    """The smallest 2^a 3^b 5^c at least m: FFTs that size are quick."""
    best = 1 << (m - 1).bit_length()
    five = 1
    while five < best:
        three = five
        while three < best:
            q = three
            while q < m:
                q *= 2
            best = min(best, q)
            three *= 3
        five *= 5
    return best


def circular_np(np, x, h):
    """x convolved with h, the tail past the end folded onto the start."""
    n = len(x)
    size = fast_length(n + len(h))
    y = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(h, size), size)
    out = y[:n].copy()
    tail = y[n:n + len(h)]
    out[:len(tail)] += tail
    return out


def master_np(np, dry, target=0.13):
    """Centered, to a quiet loudness (about -18 dBFS RMS), peaks rounded off
    softly above -5 dBFS. Frames of int16, left and right."""
    x = dry.astype(np.float64)
    x -= x.mean(axis=1, keepdims=True)
    x *= target / max(float(np.sqrt(np.mean(x ** 2))), 1e-9)
    knee = 0.55
    a = np.abs(x)
    over = a > knee
    x[over] = np.sign(x[over]) * (knee + (1 - knee) * np.tanh((a[over] - knee) / (1 - knee)))
    return (np.clip(x * 0.97, -1, 1) * 32767).astype(np.int16).T.copy()


# ---------------------------------------------------------------- without numpy

def render_plain(spec):
    """The same score in plain Python: 22.05 kHz mono, wavetable pads, the
    same notes and beat, a shorter echo. int16 samples."""
    sr = PLAIN_SR
    score = Score(spec)
    spb = 60.0 / spec["bpm"] * sr
    n = int(round(score.beats * spb))
    out = [0.0] * n
    wet = [0.0] * n
    rng = random.Random(spec["seed"])

    def at(beat):
        return int(round(beat * spb))

    def add(buf, sig, start, gain):
        pos, done, size = start % n, 0, len(sig)
        while done < size:
            take = min(size - done, n - pos)
            buf[pos:pos + take] = [a + b * gain for a, b in zip(buf[pos:pos + take], sig[done:done + take])]
            done += take
            pos = 0

    # Pads: a two-second loop a chord, every voice tuned to a whole number of
    # cycles in it, two voices a note half a hertz apart.
    size_t = 2048
    table = [sum(h ** -1.5 * math.sin(2 * math.pi * h * i / size_t) for h in range(1, 7)) for i in range(size_t)]
    top = max(abs(v) for v in table)
    table = [v / top for v in table]
    loop = 2 * sr
    loops = []
    for chord in score.chords:
        buf = [0.0] * loop
        for m in chord:
            for detune in (-0.5, 0.5):
                step = round((hz(m) + detune) * 2) / 2 * size_t / sr
                p0 = rng.random() * size_t
                buf = [a + table[int(p0 + step * i) % size_t] for i, a in enumerate(buf)]
        rms = math.sqrt(sum(v * v for v in buf) / loop)
        loops.append([v / rms for v in buf])
    pad = spec["pad"]
    half = int(spb)
    ramp = [math.sin(0.5 * math.pi * (i + 0.5) / (2 * half)) for i in range(2 * half)]
    for slot in range(score.beats // score.chord_beats):
        start, end = at(slot * score.chord_beats) - half, at((slot + 1) * score.chord_beats) + half
        size = end - start
        off = rng.randrange(loop)
        sig = (loops[slot % len(loops)] * ((off + size) // loop + 1))[off:off + size]
        window = ramp + [1.0] * (size - 4 * half) + ramp[::-1]
        level = pad["level"] * score.level("pad", (slot + 0.5) * score.chord_beats)
        add(out, [a * b for a, b in zip(sig, window)], start, level)

    made = {}

    def note(kind, m):
        key = (kind, m)
        if key not in made:
            made[key] = tone_plain(kind, m, sr)
        return made[key]

    for beat, pitch, gain, size in score.bass():
        add(out, bass_plain(pitch, size * spb / sr, spec["bass"]["style"], sr), at(beat), gain * 0.9)
    if spec.get("drums"):
        kit = kit_plain(rng, sr, spb)
        for beat, name, gain, _ in score.drums():
            add(out, kit[name], at(beat), gain)
    for i, layer in enumerate(spec.get("keys", [])):
        for beat, pitch, gain, _ in score.keys(layer, "keys%d" % i):
            add(wet, note(layer["kind"], pitch), at(beat), gain)
    for beat, pitch, gain, _ in score.bell():
        add(wet, note("bell", pitch), at(beat), gain)
    delay = at(spec["echo"]["beats"])
    g1, g2 = spec["echo"]["mix"] * 0.7, spec["echo"]["mix"] * spec["echo"]["feedback"] * 0.6
    echoed = [a + b * g1 + c * g2 for a, b, c in zip(wet, wet[-delay:] + wet[:-delay], wet[-2 * delay:] + wet[:-2 * delay])]
    out = [a + b for a, b in zip(out, echoed)]

    tx = spec.get("textures", {})
    if tx.get("vinyl") or tx.get("rain") or tx.get("drips"):
        ticks = []
        for _ in range(int(n / sr * (7 if tx.get("vinyl") else 40))):
            size = rng.randint(3, 14)
            p = rng.randrange(n - size)
            g = min(rng.expovariate(1.0), 4.0) * (0.012 if tx.get("vinyl") else 0.006)
            for j in range(size):
                out[p + j] += rng.gauss(0, 1) * g * math.exp(-j / (size / 3.0))
        if tx.get("drips"):
            for _ in range(int(n / sr * 0.3)):
                f0, p = rng.uniform(700, 1500), rng.randrange(n - sr // 5)
                for j in range(sr // 5):
                    t = j / sr
                    out[p + j] += 0.03 * math.sin(2 * math.pi * f0 * (t + 0.9 * (t - 0.01 * (1 - math.exp(-t / 0.01))))) * math.exp(-t / 0.045)
    if tx.get("sea"):
        bed, s = [], 0.0
        for _ in range(sr * 2):
            s += 0.05 * (rng.gauss(0, 1) - s)
            bed.append(s)
        level = 0.04 * tx["sea"]
        reps = n // len(bed) + 1
        bed = (bed * reps)[:n]
        waves = max(1, round(n / sr / 9.5))
        out = [a + b * level * (0.3 + 0.7 * (0.5 - 0.5 * math.cos(2 * math.pi * i * waves / n)))
               for i, (a, b) in enumerate(zip(out, bed))]

    mean = sum(out) / n
    rms = math.sqrt(sum((v - mean) ** 2 for v in out) / n) or 1.0
    gain = 0.13 / rms
    knee = 0.55
    pcm = array("h")
    for v in out:
        x = (v - mean) * gain
        a = abs(x)
        if a > knee:
            x = math.copysign(knee + (1 - knee) * math.tanh((a - knee) / (1 - knee)), x)
        pcm.append(int(max(-1.0, min(1.0, x * 0.97)) * 32767))
    return pcm


def tone_plain(kind, m, sr):
    partials = {
        "kalimba": [(1, 1.0, 2.4), (2, 0.3, 6.0), (3, 0.14, 11.0), (5.95, 0.07, 26.0)],
        "harp": [(h * (1 + 0.0002 * h * h), 0.85 ** h / h ** 0.6, 1.6 + 1.3 * h) for h in range(1, 6)],
        "epiano": [(1, 1.0, 1.3), (2, 0.35, 3.0), (3, 0.12, 6.0), (4, 0.08, 12.0)],
        "pluck": [(h, 1.0 / h, 3.5 + 5.0 * h) for h in range(1, 6)],
        "bell": [(1, 1.0, 0.9), (2, 0.35, 1.7), (3, 0.18, 3.2), (4.16, 0.08, 6.0)],
    }[kind]
    size = int(min(RING[kind], 1.3) * sr)
    f = hz(m)
    y = [0.0] * size
    for ratio, amp, decay in partials:
        if f * ratio > sr / 2.3:
            continue
        w, d = 2 * math.pi * f * ratio / sr, decay / sr
        y = [a + amp * math.sin(w * i) * math.exp(-d * i) for i, a in enumerate(y)]
    rise = int(0.003 * sr)
    for i in range(rise):
        y[i] *= i / rise
    fade = int(0.05 * sr)
    for i in range(fade):
        y[size - 1 - i] *= i / fade
    top = max(abs(v) for v in y) or 1.0
    return [v / top for v in y]


def bass_plain(m, length, style, sr):
    size = max(1, int(length * sr))
    w = 2 * math.pi * hz(m) / sr
    rise = 0.08 if style == "long" else 0.008
    tail = min(size, int((0.45 if style == "long" else 0.07) * sr))
    y = []
    for i in range(size):
        t = i / sr
        env = (1 - math.exp(-t / rise)) * (0.8 + 0.2 * math.exp(-t / 1.5) if style == "long" else 0.55 + 0.45 * math.exp(-t / 0.35))
        if i >= size - tail:
            env *= math.cos(0.5 * math.pi * (i - size + tail) / tail)
        y.append((math.sin(w * i) + 0.22 * math.sin(2 * w * i)) * env / 1.25)
    return y


def kit_plain(rng, sr, spb):
    def lowpass(x, k):
        y, s = [], 0.0
        for v in x:
            s += k * (v - s)
            y.append(s)
        return y

    def highpass(x, k):
        low = lowpass(x, k)
        return [a - b for a, b in zip(x, low)]

    def peak(y, top=1.0):
        m = max(abs(v) for v in y) or 1.0
        return [v / m * top for v in y]

    kit = {}
    size = int(0.45 * sr)
    phase, body = 0.0, []
    for i in range(size):
        t = i / sr
        phase += 2 * math.pi * (46.0 + 70.0 * math.exp(-t / 0.03)) / sr
        body.append(math.tanh(1.6 * math.sin(phase) * math.exp(-t / 0.17)))
    kit["kick"] = peak(body)
    size = int(0.6 * sr)
    noise = highpass(lowpass([rng.gauss(0, 1) for _ in range(size)], 0.6), 0.12)
    kit["snare"] = peak([v * (1 - math.exp(-i / sr / 0.005)) * (0.65 * math.exp(-i / sr / 0.075) + 0.35 * math.exp(-i / sr / 0.28))
                         for i, v in enumerate(noise)])
    size = int(0.12 * sr)
    kit["rim"] = peak([0.6 * math.sin(2 * math.pi * 1700 * i / sr) * math.exp(-i / sr / 0.012) for i in range(size)])
    size = int(0.14 * sr)
    kit["hat"] = peak([v * math.exp(-i / sr / 0.03) for i, v in enumerate(highpass([rng.gauss(0, 1) for _ in range(size)], 0.5))])
    size = int(spb)
    swish = highpass(lowpass([rng.gauss(0, 1) for _ in range(size)], 0.5), 0.1)
    kit["swish"] = peak([v * math.sin(math.pi * i / size) ** 1.5 for i, v in enumerate(swish)])
    return kit


# ---------------------------------------------------------------- files

def ffmpeg():
    for path in (shutil.which("ffmpeg"), "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"):
        if path and os.access(path, os.X_OK):
            return path
    return None


def encoder(tool):
    """AudioToolbox's AAC when ffmpeg has it (better at 128 kbps), else ffmpeg's own."""
    try:
        listed = subprocess.run([tool, "-hide_banner", "-encoders"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return "aac"
    return "aac_at" if " aac_at " in listed else "aac"


def found(cache, tid):
    """The track's file in the cache, if it is there."""
    for ext in (".m4a", ".wav"):
        path = Path(cache) / (tid + ext)
        if path.is_file() and path.stat().st_size > 1024:
            return path
    return None


def stale(cache):
    """The cache was made by another VERSION, or not finished."""
    try:
        return (Path(cache) / "version").read_text().strip() != VERSION
    except OSError:
        return True


def make(job):
    """One track into the cache: rendered, then encoded (or written as WAV)."""
    tid, cache, plain, stats = job
    spec = BY_ID[tid]
    began = time.time()
    if plain:
        pcm, rate, channels = render_plain(spec).tobytes(), PLAIN_SR, 1
    else:
        pcm, rate, channels = render(spec, stats).tobytes(), SR, 2
    rendered = time.time() - began
    cache = Path(cache)
    tool = ffmpeg()
    part = cache / ("%s.%d.part" % (tid, os.getpid()))
    if tool:
        final = cache / (tid + ".m4a")
        # The plain engine's mono, to both ears at its own level, a short
        # echo for some room.
        shape = ["-af", "aresample=44100,pan=stereo|c0=c0|c1=c0,aecho=1.0:0.95:31|57:0.18|0.12"] if plain else []
        cmd = [tool, "-hide_banner", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(rate), "-ac", str(channels),
               "-i", "pipe:0", *shape, "-ac", "2", "-c:a", encoder(tool), "-b:a", "128k",
               "-metadata", "title=" + spec["title"], "-metadata", "artist=" + spec["artist"],
               "-metadata", "album=" + spec["title"],
               "-metadata", "comment=Synthesized by Drift's make_audio.py, a made-up service for Yab's demos.",
               "-movflags", "+faststart", "-f", "ipod", str(part)]
        subprocess.run(cmd, input=pcm, check=True)
    else:
        final = cache / (tid + ".wav")
        with wave.open(str(part), "wb") as out:
            out.setnchannels(channels)
            out.setsampwidth(2)
            out.setframerate(rate)
            out.writeframes(pcm)
    os.replace(part, final)
    for ext in (".m4a", ".wav"):
        other = cache / (tid + ext)
        if other != final and other.exists():
            other.unlink()
    return tid, final.name, rendered, time.time() - began


def numpy_elsewhere():
    """Another python3 on this Mac that has numpy, for a Python that hasn't."""
    home = Path.home()
    places = [shutil.which("python3"), "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
              str(home / "miniconda/bin/python3"), str(home / "miniconda3/bin/python3"),
              str(home / "anaconda3/bin/python3"), str(home / ".pyenv/shims/python3"),
              "/Library/Frameworks/Python.framework/Versions/Current/bin/python3", "/usr/bin/python3"]
    seen = {os.path.realpath(sys.executable)}
    for place in places:
        if not place or not os.access(place, os.X_OK) or os.path.realpath(place) in seen:
            continue
        seen.add(os.path.realpath(place))
        try:
            if subprocess.run([place, "-c", "import numpy"], capture_output=True, timeout=20).returncode == 0:
                return place
        except (OSError, subprocess.SubprocessError):
            continue
    return None


def make_audio(args):
    cache = Path(args.cache).expanduser() if args.cache else CACHE
    cache.mkdir(parents=True, exist_ok=True)
    if stale(cache):
        # Another version's music, or none: start this version's afresh. What
        # is made from here on is this version's, so the stamp goes first.
        for tid in IDS:
            for ext in (".m4a", ".wav"):
                (cache / (tid + ext)).unlink(missing_ok=True)
        (cache / "version").write_text(VERSION + "\n")
    wanted = [t for t in (args.only.split(",") if args.only else IDS) if t]
    unknown = [t for t in wanted if t not in BY_ID]
    if unknown:
        sys.exit("make_audio: no track %s (have %s)" % (", ".join(unknown), ", ".join(IDS)))
    todo = [t for t in wanted if args.force or not found(cache, t)]
    if not todo:
        print("drift: all %d tracks already in %s" % (len(wanted), cache))
        return
    try:
        import numpy  # noqa: F401
        plain = False
    except ImportError:
        plain = True
        if not os.environ.get("DRIFT_PLAIN"):
            other = numpy_elsewhere()
            if other:
                os.environ["DRIFT_PLAIN"] = "1"
                os.execv(other, [other, str(Path(__file__).resolve())] + sys.argv[1:])
    if os.environ.get("DRIFT_PLAIN") == "force":
        plain = True
    began = time.time()
    jobs = [(t, str(cache), plain, args.stats) for t in todo]
    workers = max(1, min(len(jobs), (os.cpu_count() or 2) // 2, 6))
    if workers > 1:
        import multiprocessing
        with multiprocessing.get_context("spawn").Pool(workers) as pool:
            done = pool.map(make, jobs)
    else:
        done = [make(job) for job in jobs]
    for tid, name, rendered, total in done:
        print("drift: %-15s %-20s %5.1f s to render, %5.1f s in all" % (tid, name, rendered, total))
    print("drift: %d track%s in %.1f s (%s engine) into %s" % (
        len(done), "" if len(done) == 1 else "s", time.time() - began, "plain" if plain else "numpy", cache))


# ---------------------------------------------------------------- covers

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Helvetica Neue', Helvetica, Arial, sans-serif"


def stops(items):
    out = []
    for item in items:
        offset, color = item[0], item[1]
        alpha = "" if len(item) < 3 else ' stop-opacity="%s"' % item[2]
        out.append('<stop offset="%s" stop-color="%s"%s/>' % (offset, color, alpha))
    return "".join(out)


def linear(gid, items, x1=0, y1=0, x2=0, y2=1):
    return '<linearGradient id="%s" x1="%s" y1="%s" x2="%s" y2="%s">%s</linearGradient>' % (gid, x1, y1, x2, y2, stops(items))


def radial(gid, items, cx=0.5, cy=0.5, r=0.5):
    return '<radialGradient id="%s" cx="%s" cy="%s" r="%s">%s</radialGradient>' % (gid, cx, cy, r, stops(items))


GRAIN_DEF = ('<filter id="grain" x="0" y="0" width="100%" height="100%">'
             '<feTurbulence type="fractalNoise" baseFrequency=".9" numOctaves="2" seed="7" stitchTiles="stitch"/>'
             '<feColorMatrix type="saturate" values="0"/></filter>')
GRAIN = '<rect width="512" height="512" filter="url(#grain)" opacity=".16" style="mix-blend-mode:soft-light"/>'


def svg(defs, body, grain=True, label=""):
    title = "<title>%s</title>" % label if label else ""
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">%s'
            '<defs>%s%s</defs>%s%s</svg>\n') % (title, defs, GRAIN_DEF if grain else "", body, GRAIN if grain else "")


def mark(x, y, size, plain=False):
    """Drift's mark, a sun going down into two waves, `size` across at x, y."""
    s = size / 64.0
    tile = '<rect width="64" height="64" rx="15" fill="url(#markTile)"/>' if not plain else ""
    ink = "#fff"
    return ('<g transform="translate(%s %s) scale(%s)">%s'
            '<path d="M18 37 A14 14 0 0 1 46 37 Z" fill="%s"/>'
            '<path d="M10 44 q5.5 -4.5 11 0 t11 0 t11 0 t11 0" fill="none" stroke="%s" stroke-width="4.4" stroke-linecap="round"/>'
            '<path d="M17 53 q5 -4 10 0 t10 0 t10 0" fill="none" stroke="%s" stroke-width="4.4" stroke-linecap="round" opacity=".85"/>'
            '</g>') % (x, y, s, tile, ink, ink, ink)


MARK_TILE = linear("markTile", [(0, "#ff9e6e"), (0.55, "#ff6f5a"), (1, "#ef4f5e")], 0, 0, 0.4, 1)


def paper_lanterns(grain=True):
    lanterns = [(148, 236, 92, 116), (300, 152, 70, 88), (388, 304, 112, 138)]
    defs = (linear("sky", [(0, "#1c1030"), (0.42, "#4a1d47"), (0.78, "#b5453c"), (1, "#f29a4e")])
            + radial("halo", [(0, "#ffb870", 0.72), (0.45, "#ff8c4f", 0.22), (1, "#ff8c4f", 0)])
            + radial("paper", [(0, "#fff6dc"), (0.45, "#ffcd80"), (1, "#ee763c")], 0.45, 0.38, 0.7)
            + radial("ground", [(0, "#ffb26a", 0.5), (1, "#ffb26a", 0)]))
    body = ['<rect width="512" height="512" fill="url(#sky)"/>',
            '<ellipse cx="256" cy="560" rx="420" ry="190" fill="url(#ground)"/>']
    for cx, cy, w, h in lanterns:
        body.append('<circle cx="%s" cy="%s" r="%s" fill="url(#halo)"/>' % (cx, cy, h * 1.45))
    for cx, cy, w, h in lanterns:
        top, bottom = cy - h / 2, cy + h / 2
        body.append('<path d="M%s -4 V%s" stroke="#ffd6a0" stroke-opacity=".38" stroke-width="2"/>' % (cx, top - 8))
        body.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="url(#paper)"/>' % (cx - w / 2, top, w, h, w * 0.42))
        for f in (-0.27, 0.0, 0.27):
            y = cy + f * h
            sag = 5 + 2 * abs(f)
            body.append('<path d="M%s %s Q%s %s %s %s" fill="none" stroke="#c95a2f" stroke-opacity=".28" stroke-width="1.6"/>'
                        % (cx - w / 2 + 3, y, cx, y + sag, cx + w / 2 - 3, y))
        cap = w * 0.42
        body.append('<rect x="%s" y="%s" width="%s" height="9" rx="2.5" fill="#2b1426"/>' % (cx - cap / 2, top - 6, cap))
        body.append('<rect x="%s" y="%s" width="%s" height="9" rx="2.5" fill="#2b1426"/>' % (cx - cap / 2, bottom - 3, cap))
        body.append('<path d="M%s %s v18" stroke="#ff9d5c" stroke-opacity=".7" stroke-width="2" stroke-linecap="round"/>' % (cx, bottom + 6))
    return svg(defs, "".join(body), grain, "Paper Lanterns")


def ridge(rng, base, amp, phase, tree_h, step):
    """A hillside with cedars along its top, as one closed path."""
    def y(x):
        return base + amp * math.sin(x * 0.011 + phase) + amp * 0.45 * math.sin(x * 0.027 + phase * 1.7)
    line = " ".join("L%.1f %.1f" % (x, y(x)) for x in range(-10, 530, 8))
    path = "M-10 520 %s L522 520 Z" % line
    trees = []
    x = -6.0
    while x < 520:
        h = tree_h * rng.uniform(0.55, 1.15)
        w = h * rng.uniform(0.32, 0.42)
        ground = y(x) + 2
        trees.append("M%.1f %.1f L%.1f %.1f L%.1f %.1f Z" % (x - w / 2, ground, x, ground - h, x + w / 2, ground))
        x += step * rng.uniform(0.6, 1.4)
    return path + " " + " ".join(trees)


def cedar_and_salt(grain=True):
    rng = random.Random(23)
    defs = (linear("sky", [(0, "#eef6ef"), (0.5, "#cdeadb"), (1, "#9dd3b7")])
            + radial("sunglow", [(0, "#fffaf0", 0.9), (1, "#fffaf0", 0)])
            + linear("mist", [(0, "#f4f8f2", 0), (0.5, "#f4f8f2", 0.55), (1, "#f4f8f2", 0)]))
    body = ['<rect width="512" height="512" fill="url(#sky)"/>',
            '<circle cx="334" cy="176" r="150" fill="url(#sunglow)"/>',
            '<circle cx="334" cy="176" r="62" fill="#f8ecd0"/>',
            '<path d="%s" fill="#84c49f"/>' % ridge(rng, 300, 14, 0.6, 26, 15),
            '<rect y="292" width="512" height="56" fill="url(#mist)"/>',
            '<path d="%s" fill="#3a9670"/>' % ridge(rng, 352, 16, 2.1, 38, 17),
            '<rect y="352" width="512" height="52" fill="url(#mist)" opacity=".7"/>',
            '<path d="%s" fill="#1c6e54"/>' % ridge(rng, 404, 12, 4.0, 52, 20),
            '<path d="%s" fill="#0e4436"/>' % ridge(rng, 462, 10, 5.3, 64, 24)]
    return svg(defs, "".join(body), grain, "Cedar and Salt")


def linen_hours(grain=True):
    rng = random.Random(37)
    defs = (linear("bg", [(0, "#fbe4da"), (0.55, "#f4b6b5"), (1, "#dd86a2")], 0, 0, 0.35, 1)
            + linear("fold", [(0, "#de7d96", 0.55), (0.32, "#fff4ec", 0.85), (0.6, "#ffe6e0", 0.55), (1, "#d97792", 0.55)], 0, 0, 1, 0)
            + radial("sun", [(0, "#fff8ee", 0.95), (0.4, "#fff1e2", 0.45), (1, "#fff1e2", 0)])
            + linear("floor", [(0, "#c77d98", 0), (1, "#b56b8c", 0.55)]))
    body = ['<rect width="512" height="512" fill="url(#bg)"/>']
    x = -20.0
    while x < 512:
        w = rng.uniform(58, 96)
        sway, phase = rng.uniform(6, 14), rng.uniform(0, 6.3)
        hem = 452 + rng.uniform(-14, 18)

        def edge(x0, sign):
            return [(x0 + sway * math.sin(yy * 0.009 + phase) * sign * 0.4 + sway * (yy / 512.0) ** 2 * sign, yy)
                    for yy in range(-10, int(hem) + 1, 16)]
        left, right = edge(x, -1), edge(x + w, 1)
        # Down one side, a soft hem across the bottom, up the other.
        d = ("M" + " L".join("%.1f %.1f" % p for p in left)
             + " Q%.1f %.1f %.1f %.1f" % (x + w * 0.5, hem + 18, right[-1][0], right[-1][1])
             + " L" + " L".join("%.1f %.1f" % p for p in right[::-1]) + " Z")
        body.append('<path d="%s" fill="url(#fold)"/>' % d)
        x += w * rng.uniform(0.78, 0.92)
    body += ['<circle cx="372" cy="138" r="230" fill="url(#sun)"/>',
             '<rect y="392" width="512" height="120" fill="url(#floor)"/>']
    return svg(defs, "".join(body), grain, "Linen Hours")


def low_tide(grain=True):
    rng = random.Random(41)
    horizon = 322
    cuts = []
    for i in range(6):
        y = horizon - 10 - i * 15 - i * i * 1.8
        cuts.append('<rect x="120" y="%.1f" width="272" height="%.1f" fill="#000"/>' % (y, max(1.6, 7.0 - i * 1.1)))
    defs = (linear("sky", [(0, "#0a1f45"), (0.62, "#2b5f97")])
            + linear("sea", [(0, "#174270"), (1, "#081a36")])
            + linear("sun", [(0, "#fff0dd"), (1, "#f5b892")])
            + radial("glow", [(0, "#ffd9bd", 0.42), (1, "#ffd9bd", 0)])
            + '<mask id="cut"><rect width="512" height="512" fill="#fff"/>%s</mask>' % "".join(cuts)
            + '<clipPath id="above"><rect width="512" height="%s"/></clipPath>' % horizon)
    body = ['<rect width="512" height="%s" fill="url(#sky)"/>' % horizon,
            '<rect y="%s" width="512" height="%s" fill="url(#sea)"/>' % (horizon, 512 - horizon),
            '<ellipse cx="256" cy="%s" rx="300" ry="170" fill="url(#glow)"/>' % horizon,
            '<g clip-path="url(#above)" mask="url(#cut)"><circle cx="256" cy="%s" r="112" fill="url(#sun)"/></g>' % horizon]
    for j in range(11):
        y = horizon + 10 + j * 15 + j * j * 0.7
        w = max(18.0, 210 - j * 17 + rng.uniform(-12, 12))
        x = 256 - w / 2 + rng.uniform(-8, 8)
        body.append('<rect x="%.1f" y="%.1f" width="%.1f" height="3.6" rx="1.8" fill="#f8cdb0" opacity="%.2f"/>'
                    % (x, y, w, max(0.08, 0.6 - j * 0.05)))
    for _ in range(16):
        y = rng.uniform(horizon + 12, 505)
        x = rng.uniform(-40, 470)
        body.append('<rect x="%.1f" y="%.1f" width="%.1f" height="1.6" rx=".8" fill="#9fcbee" opacity="%.2f"/>'
                    % (x, y, rng.uniform(40, 120), rng.uniform(0.08, 0.2)))
    return svg(defs, "".join(body), grain, "Low Tide")


def night_ferry(grain=True):
    rng = random.Random(53)
    horizon = 346
    defs = (linear("sky", [(0, "#0b0a24"), (0.66, "#2a1b62"), (1, "#4c3195")])
            + linear("sea", [(0, "#1d1656"), (1, "#09081d")])
            + radial("moonglow", [(0, "#b3a1ff", 0.5), (1, "#b3a1ff", 0)])
            + linear("band", [(0, "#7a5cf0", 0), (1, "#8c6cff", 0.42)])
            + '<mask id="crescent"><circle cx="360" cy="136" r="44" fill="#fff"/><circle cx="380" cy="122" r="40" fill="#000"/></mask>')
    body = ['<rect width="512" height="%s" fill="url(#sky)"/>' % horizon,
            '<rect y="%s" width="512" height="70" fill="url(#band)"/>' % (horizon - 70)]
    for _ in range(26):
        body.append('<circle cx="%.1f" cy="%.1f" r="%.2f" fill="#fff" opacity="%.2f"/>'
                    % (rng.uniform(8, 504), rng.uniform(8, horizon - 90), rng.uniform(0.7, 1.8), rng.uniform(0.3, 0.9)))
    body += ['<circle cx="360" cy="136" r="160" fill="url(#moonglow)"/>',
             '<circle cx="360" cy="136" r="44" fill="#f1ecff" mask="url(#crescent)"/>',
             '<rect y="%s" width="512" height="%s" fill="url(#sea)"/>' % (horizon, 512 - horizon)]
    for j in range(12):
        y = horizon + 10 + j * 13 + j * j * 0.45
        w = max(10.0, 74 - j * 5.5 + rng.uniform(-6, 6))
        body.append('<rect x="%.1f" y="%.1f" width="%.1f" height="3" rx="1.5" fill="#cfc3ff" opacity="%.2f"/>'
                    % (352 - w / 2 + rng.uniform(-5, 5), y, w, max(0.06, 0.5 - j * 0.04)))
    hull = "M86 %s L304 %s L292 %s L100 %s Z" % (horizon, horizon, horizon + 13, horizon + 13)
    body += ['<path d="%s" fill="#0c0a24"/>' % hull,
             '<rect x="112" y="%s" width="156" height="17" rx="3" fill="#0c0a24"/>' % (horizon - 16),
             '<rect x="214" y="%s" width="40" height="13" rx="2" fill="#0c0a24"/>' % (horizon - 28),
             '<rect x="232" y="%s" width="10" height="14" rx="1.5" fill="#0c0a24"/>' % (horizon - 41)]
    x = 120
    while x < 262:
        if rng.random() < 0.82:
            body.append('<rect x="%s" y="%s" width="4.6" height="4.2" rx="1" fill="#ffd27e"/>' % (x, horizon - 11))
            for k in range(4):
                body.append('<rect x="%s" y="%.1f" width="4.6" height="2.4" rx="1" fill="#ffd27e" opacity="%.2f"/>'
                            % (x + rng.uniform(-1.5, 1.5), horizon + 20 + k * 9 + rng.uniform(-2, 2), 0.32 - k * 0.07))
        x += 9
    body.append('<rect x="221" y="%s" width="5" height="4" rx="1" fill="#ffd27e"/>' % (horizon - 24))
    return svg(defs, "".join(body), grain, "Night Ferry")


def moon_pool(grain=True):
    defs = (radial("pool", [(0, "#ffa3d8"), (0.26, "#d9489f"), (0.6, "#7c1d70"), (1, "#2a0a35")], 0.5, 0.62, 0.78)
            + radial("glow", [(0, "#fff0f8", 0.85), (0.35, "#ffd2ec", 0.35), (1, "#ffd2ec", 0)])
            + radial("moonhalo", [(0, "#ffe6f4", 0.5), (1, "#ffe6f4", 0)]))
    body = ['<rect width="512" height="512" fill="url(#pool)"/>',
            '<circle cx="146" cy="104" r="96" fill="url(#moonhalo)"/>',
            '<circle cx="146" cy="104" r="26" fill="#ffeef8"/>']
    for k in range(7):
        rx = 44 * 1.36 ** k
        body.append('<ellipse cx="270" cy="338" rx="%.1f" ry="%.1f" fill="none" stroke="#ffe0f2" stroke-width="%.2f" opacity="%.2f"/>'
                    % (rx, rx * 0.5, max(0.9, 3.0 - 0.33 * k), max(0.08, 0.55 - 0.07 * k)))
    body += ['<ellipse cx="270" cy="338" rx="110" ry="58" fill="url(#glow)"/>',
             '<ellipse cx="270" cy="338" rx="26" ry="12" fill="#fff3fa"/>']
    return svg(defs, "".join(body), grain, "Moon Pool")


def titled(defs, art, title, eyebrow, ink="#fff", sub_ink=None, grain=True):
    """A station's or a mix's cover: art, Drift's mark and words over it."""
    sub_ink = sub_ink or ink
    size = 60 if len(title) <= 10 else 52 if len(title) <= 12 else 46
    words = ('<g font-family="%s">'
             '<text x="72" y="48" font-size="17" font-weight="600" fill="%s" opacity=".85" letter-spacing=".2">%s</text>'
             '<text x="34" y="458" font-size="%s" font-weight="800" fill="%s" letter-spacing="-1.4">%s</text>'
             '</g>') % (FONT, sub_ink, eyebrow, size, ink, title)
    return svg(MARK_TILE + defs, art + mark(30, 26, 30) + words, grain, title)


def station_cover(sid, grain=True):
    rng = random.Random(sid)
    if sid == "morning-fog":
        defs = (linear("bg", [(0, "#f7cdb0"), (0.5, "#ebb8c3"), (1, "#bcb4de")])
                + radial("sun", [(0, "#fffaf2", 0.95), (1, "#fffaf2", 0)])
                + linear("fog", [(0, "#fff", 0), (0.5, "#fff", 0.6), (1, "#fff", 0)]))
        art = ['<rect width="512" height="512" fill="url(#bg)"/>',
               '<circle cx="352" cy="168" r="170" fill="url(#sun)"/>',
               '<circle cx="352" cy="168" r="64" fill="#fff6ec"/>',
               '<path d="M-10 300 C90 262 190 270 280 296 S440 330 522 284 V520 H-10 Z" fill="#a597cc" opacity=".55"/>',
               '<rect y="258" width="512" height="80" fill="url(#fog)"/>',
               '<path d="M-10 352 C110 320 220 338 330 358 S470 372 522 340 V520 H-10 Z" fill="#8c7eb9" opacity=".7"/>',
               '<rect y="318" width="512" height="90" fill="url(#fog)" opacity=".8"/>',
               '<path d="M-10 410 C120 388 240 404 360 418 S480 420 522 404 V520 H-10 Z" fill="#7c6aa8" opacity=".55"/>',
               '<rect y="392" width="512" height="70" fill="url(#fog)" opacity=".55"/>']
        return titled(defs, "".join(art), "Morning Fog", "Drift Radio", "#33203f", "#33203f", grain)
    if sid == "night-swim":
        defs = (linear("bg", [(0, "#040e20"), (0.5, "#0a2a4b"), (1, "#0f4b6c")])
                + radial("moon", [(0, "#a8d8ff", 0.45), (1, "#a8d8ff", 0)]))
        art = ['<rect width="512" height="512" fill="url(#bg)"/>',
               '<circle cx="300" cy="128" r="190" fill="url(#moon)"/>',
               '<circle cx="300" cy="128" r="48" fill="#eaf6ff"/>']
        for k in range(6):
            rx = 70 + k * 46
            art.append('<ellipse cx="300" cy="352" rx="%s" ry="%.1f" fill="none" stroke="#bfe4ff" stroke-width="1.6" opacity="%.2f"/>'
                       % (rx, rx * 0.24, max(0.08, 0.4 - k * 0.06)))
        for j in range(9):
            w = 64 - j * 6
            art.append('<rect x="%.1f" y="%s" width="%s" height="3" rx="1.5" fill="#d6efff" opacity="%.2f"/>'
                       % (300 - w / 2 + rng.uniform(-4, 4), 240 + j * 13, w, 0.5 - j * 0.045))
        return titled(defs, "".join(art), "Night Swim", "Drift Radio", grain=grain)
    if sid == "slow-focus":
        defs = linear("bg", [(0, "#0e2e2b"), (0.55, "#1d5a4e"), (1, "#5e9d84")], 0, 0, 0.6, 1)
        art = ['<rect width="512" height="512" fill="url(#bg)"/>',
               '<circle cx="320" cy="214" r="168" fill="none" stroke="#e9f3e8" stroke-width="1.5" opacity=".22"/>',
               '<circle cx="320" cy="214" r="112" fill="none" stroke="#e9f3e8" stroke-width="1.5" opacity=".32"/>',
               '<circle cx="320" cy="214" r="58" fill="none" stroke="#e9f3e8" stroke-width="1.8" opacity=".5"/>',
               '<circle cx="320" cy="214" r="20" fill="#f3efe0"/>']
        return titled(defs, "".join(art), "Slow Focus", "Drift Radio", grain=grain)
    defs = (linear("bg", [(0, "#1b2232"), (0.55, "#33415d"), (1, "#5d7096")])
            + radial("lamp", [(0, "#ffcc84", 0.6), (1, "#ffcc84", 0)]))
    art = ['<rect width="512" height="512" fill="url(#bg)"/>',
           '<circle cx="408" cy="430" r="230" fill="url(#lamp)"/>']
    for _ in range(130):
        x, y, size = rng.uniform(-20, 520), rng.uniform(-20, 500), rng.uniform(14, 40)
        art.append('<path d="M%.1f %.1f l%.1f %.1f" stroke="#d8e6ff" stroke-width="1.3" stroke-linecap="round" opacity="%.2f"/>'
                   % (x, y, -size * 0.26, size, rng.uniform(0.1, 0.38)))
    return titled(defs, "".join(art), "Rain Room", "Drift Radio", grain=grain)


MIXES = {
    "friday-mix": ("Friday Mix", ("#ff8a5c", "#f2545b"), "sun"),
    "daily-drift-1": ("Daily Drift 1", ("#c9b458", "#6f9a63"), "waves"),
    "daily-drift-2": ("Daily Drift 2", ("#3557c9", "#1b8a9a"), "rings"),
    "on-repeat": ("On Repeat", ("#c13f95", "#6a35c9"), "loop"),
    "slow-sunday": ("Slow Sunday", ("#efc29a", "#d98a7a"), "rise"),
}


def mix_cover(mid, grain=True):
    title, (a, b), shape = MIXES[mid]
    defs = linear("bg", [(0, a), (1, b)], 0, 0, 1, 1)
    art = ['<rect width="512" height="512" fill="url(#bg)"/>']
    if shape == "sun":
        art += ['<circle cx="350" cy="200" r="150" fill="#fff" opacity=".16"/>', '<circle cx="350" cy="200" r="86" fill="#ffd9a8" opacity=".9"/>']
    elif shape == "waves":
        for k in range(5):
            y = 150 + k * 44
            art.append('<path d="M-20 %s q40 -26 80 0 t80 0 t80 0 t80 0 t80 0 t80 0 t80 0" fill="none" stroke="#fff" stroke-width="10" stroke-linecap="round" opacity="%.2f"/>'
                       % (y, 0.55 - k * 0.08))
    elif shape == "rings":
        for k in range(5):
            art.append('<circle cx="340" cy="210" r="%s" fill="none" stroke="#fff" stroke-width="14" opacity="%.2f"/>' % (40 + k * 40, 0.5 - k * 0.08))
    elif shape == "loop":
        art += ['<circle cx="290" cy="210" r="104" fill="none" stroke="#fff" stroke-width="22" opacity=".5"/>',
                '<circle cx="380" cy="210" r="104" fill="none" stroke="#ffd1ef" stroke-width="22" opacity=".55"/>']
    else:
        art += ['<path d="M150 320 A140 140 0 0 1 430 320 Z" fill="#fff4e4" opacity=".85"/>',
                '<rect x="0" y="320" width="512" height="200" fill="#c9746c" opacity=".35"/>']
    return titled(defs, "".join(art), title, "Made for Mira", grain=grain)


COVERS = {
    "paper-lanterns": paper_lanterns, "cedar-and-salt": cedar_and_salt, "linen-hours": linen_hours,
    "low-tide": low_tide, "night-ferry": night_ferry, "moon-pool": moon_pool,
}
STATIONS = ["morning-fog", "night-swim", "slow-focus", "rain-room"]


def favicon(full_bleed=False):
    """The mark alone: its tile rounded, or for apple-touch-icon square to the edge."""
    tile = ('<rect width="64" height="64" fill="url(#markTile)"/>' if full_bleed
            else '<rect width="64" height="64" rx="15" fill="url(#markTile)"/>')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 64 64">'
            '<defs>%s</defs>%s'
            '<path d="M18 37 A14 14 0 0 1 46 37 Z" fill="#fff"/>'
            '<path d="M10 44 q5.5 -4.5 11 0 t11 0 t11 0 t11 0" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round"/>'
            '<path d="M17 53 q5 -4 10 0 t10 0 t10 0" fill="none" stroke="#fff" stroke-width="4.4" stroke-linecap="round" opacity=".85"/>'
            '</svg>\n') % (MARK_TILE, tile)


def chrome():
    for path in ("/Applications/Google Chrome Beta.app/Contents/MacOS/Google Chrome Beta",
                 "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                 "/Applications/Chromium.app/Contents/MacOS/Chromium",
                 "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
                 shutil.which("chromium") or "", shutil.which("google-chrome") or ""):
        if path and os.access(path, os.X_OK):
            return path
    return None


def snap(browser, source, target, profile, size=512):
    """An SVG file as a PNG, with headless Chrome, its background clear."""
    return subprocess.Popen(
        [browser, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--no-first-run", "--no-default-browser-check",
         "--user-data-dir=" + str(profile), "--force-device-scale-factor=1", "--window-size=%d,%d" % (size, size),
         "--default-background-color=00000000", "--screenshot=" + str(target), Path(source).as_uri()],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_covers():
    covers = HERE / "covers"
    covers.mkdir(exist_ok=True)
    for tid, draw in COVERS.items():
        (covers / (tid + ".svg")).write_text(draw(True))
    for sid in STATIONS:
        (covers / (sid + ".svg")).write_text(station_cover(sid))
    for mid in MIXES:
        (covers / (mid + ".svg")).write_text(mix_cover(mid))
    (HERE / "favicon.svg").write_text(favicon().replace('width="512" height="512" ', ""))
    browser = chrome()
    if not browser:
        print("drift: no Chrome to turn covers into PNG; the SVGs stand alone")
        return
    work = Path(tempfile.mkdtemp(prefix="drift-covers-"))
    jobs = []
    try:
        for tid, draw in COVERS.items():
            flat = work / (tid + ".svg")
            flat.write_text(draw(False))
            jobs.append((flat, covers / (tid + ".png")))
        (work / "icon.svg").write_text(favicon())
        (work / "touch.svg").write_text(favicon(True))
        jobs += [(work / "icon.svg", work / "icon.png"), (work / "touch.svg", work / "touch.png")]
        running = [snap(browser, source, target, work / ("profile%d" % i)) for i, (source, target) in enumerate(jobs)]
        for proc in running:
            proc.wait(timeout=120)
        missing = [str(target) for _, target in jobs if not target.exists()]
        if missing:
            print("drift: Chrome made no %s; those covers stay SVG" % ", ".join(missing))
        sips = shutil.which("sips") or "/usr/bin/sips"
        for source, target, side in ((work / "icon.png", HERE / "favicon.png", 64),
                                     (work / "touch.png", HERE / "apple-touch-icon.png", 180)):
            subprocess.run([sips, "-z", str(side), str(side), str(source), "--out", str(target)],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    print("drift: covers and icons in %s" % HERE)


def main():
    parser = argparse.ArgumentParser(description="Drift's music and covers, synthesized.")
    parser.add_argument("cache", nargs="?", help="where the tracks go (default %s)" % CACHE)
    parser.add_argument("--only", help="just these track ids, comma separated")
    parser.add_argument("--force", action="store_true", help="make them even if they are there")
    parser.add_argument("--covers", action="store_true", help="make the covers and icons instead")
    parser.add_argument("--stats", action="store_true", help="print each bus's level while rendering")
    parser.add_argument("--list", action="store_true", help="print the tracks and their lengths")
    args = parser.parse_args()
    if args.list:
        for spec in TRACKS:
            print("%-15s %-16s %-12s %7.3f s" % (spec["id"], spec["title"], spec["artist"], seconds(spec)))
        return
    if args.covers:
        make_covers()
    else:
        make_audio(args)


if __name__ == "__main__":
    main()
