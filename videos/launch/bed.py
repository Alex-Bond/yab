#!/usr/bin/env python3
"""The three films' beds, made by Drift's own synthesizer (demos/sites/drift/
make_audio.py), so no film carries a licensed track: Drift's tracks played
at the film's own tempo and length.

    python3 bed.py        -> public/audio/bed-1.m4a, bed-2.m4a, bed-3.m4a
"""
import copy
import importlib.util
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "public" / "audio"

for root in (HERE.parents[1] / "demos", HERE.parents[1] / "demo"):
    synth = root / "sites" / "drift" / "make_audio.py"
    if synth.exists():
        break
else:
    sys.exit("Drift's make_audio.py isn't in demos/sites/drift")

spec = importlib.util.spec_from_file_location("make_audio", synth)
drift = importlib.util.module_from_spec(spec)
spec.loader.exec_module(drift)


def bed(source, tid, **change):
    made = copy.deepcopy(drift.BY_ID[source])
    made.update(id=tid, title=tid, artist="Yab", **change)
    return made


BEDS = [
    # 1. Yes, another browser: warm and sure of itself, piano, harp, brushes.
    bed("cedar-and-salt", "bed-1", bpm=96, cycles=2,
        plan=dict(pad=[0.85, 1.0], keys0=[0.8, 1.0], keys1=[0.5, 0.9], bass=[0.8, 1.0], drums=[0.6, 1.0])),
    # 2. Then we gave it hands: slow, lit from within, kalimba and bells.
    bed("paper-lanterns", "bed-2", bpm=72, cycles=2,
        plan=dict(pad=[0.9, 1.0], keys0=[0.7, 1.0], bass=[0.6, 1.0], bell=[0.6, 1.0])),
    # 3. Fast: the lo-fi kit, quicker.
    bed("night-ferry", "bed-3", bpm=112, cycles=2,
        plan=dict(pad=[0.9, 1.0], keys0=[0.9, 1.0], bass=[0.9, 1.0], drums=[0.85, 1.0])),
]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    for made in BEDS:
        drift.BY_ID[made["id"]] = made
        tid, name, rendered, took = drift.make((made["id"], str(OUT), False, False))
        print("%s: %s, %.1f s of music in %.1f s" % (tid, OUT / name, drift.seconds(made), took))


if __name__ == "__main__":
    main()
