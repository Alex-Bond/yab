"""The words in a picture as a person reads them (probe_ocr.swift, Vision),
for evals that check what the window says rather than what the app holds.

    import probe_ocr
    probe_ocr.words("shot.png")                 # every line
    probe_ocr.words("shot.png", (x, y, w, h))   # a part, in the picture's pixels from its top left
    probe_ocr.lines("shot.png")                 # [(words, (x, y, w, h))], where each line stands
"""
import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_tool = None


def _built():
    global _tool
    if _tool is None:
        path = os.path.join(tempfile.mkdtemp(prefix="yab-ocr-"), "probe_ocr")
        subprocess.run(["swiftc", "-O", os.path.join(HERE, "probe_ocr.swift"), "-o", path], check=True)
        _tool = path
    return _tool


def _run(picture, rect, boxes):
    args = [_built(), picture] + ([str(int(v)) for v in rect] if rect else [])
    env = dict(os.environ, PROBE_OCR_BOXES="1" if boxes else "0")
    return subprocess.run(args, capture_output=True, text=True, check=True, env=env).stdout.splitlines()


def words(picture, rect=None):
    return _run(picture, rect, False)


def lines(picture, rect=None):
    out = []
    for line in _run(picture, rect, True):
        text, *box = line.rsplit("\t", 4)
        out.append((text, tuple(int(v) for v in box)))
    return out
