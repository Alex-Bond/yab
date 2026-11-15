#!/usr/bin/env python3
"""Render the launch films, or a storyboard of one (stills on a sheet).

    python3 render.py board Film2          out/board-Film2.png, eight moments of the film
    python3 render.py film Film1           out/film-1.mp4 (1920x1080, 30 fps, with its bed)
    python3 render.py all                  the three films and their boards
"""
import shutil
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FILMS = {"Film1": 1080, "Film2": 966, "Film3": 972}
# Film 3 opens each beat on its key alone, so its sheet takes the middle of each.
BOARDS = {"Film3": [144, 240, 336, 432, 528, 624, 720, 816]}


def remotion(*args):
    subprocess.run(["npx", "remotion", *args, "--bundle-cache=false"], cwd=HERE, check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def board(film):
    total = FILMS[film]
    frames = BOARDS.get(film) or [int(total * k / 8) + 20 for k in range(8)]
    stills = []
    for frame in frames:
        path = OUT / ("%s-%04d.png" % (film, frame))
        remotion("still", "remotion/index.ts", film, str(path), "--frame=%d" % frame)
        stills.append(path)
    args = ["ffmpeg", "-v", "error", "-y"]
    for path in stills:
        args += ["-i", str(path)]
    scale = "".join("[%d]scale=640:-1[v%d];" % (k, k) for k in range(len(stills)))
    grid = "".join("[v%d]" % k for k in range(len(stills)))
    layout = "0_0|w0_0|0_h0|w0_h0|0_h0+h1|w0_h0+h1|0_h0+h1+h2|w0_h0+h1+h2"
    target = OUT / ("board-%s.png" % film)
    subprocess.run(args + ["-filter_complex", "%s%sxstack=inputs=%d:layout=%s" % (scale, grid, len(stills), layout), str(target)], check=True)
    print(target)


def film(name):
    target = OUT / ("film-%s.mp4" % name[-1])
    remotion("render", "remotion/index.ts", name, str(target), "--codec=h264", "--crf=16")
    print(target)


def main():
    OUT.mkdir(exist_ok=True)
    # The pen writes in the hand Yab's update note is written in (THIRD_PARTY_NOTICES.md, Caveat).
    font = HERE / "public/brand/Caveat.ttf"
    if not font.exists():
        shutil.copy(HERE.parent.parent / "Resources/Caveat.ttf", font)
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    names = sys.argv[2:] or list(FILMS)
    if what in ("board", "all"):
        for name in names:
            board(name)
    if what in ("film", "all"):
        for name in names:
            film(name)


if __name__ == "__main__":
    main()
