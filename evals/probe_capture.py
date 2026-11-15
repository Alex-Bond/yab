"""Target-window evidence for farm probes; keeps adhd's blackout raised."""
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess


def _size(path):
    if not path.is_file():
        raise RuntimeError("window capture has no image")
    header = path.read_bytes()[:24]
    if len(header) < 24 or header[:8] != b"\x89PNG\r\n\x1a\n":
        raise RuntimeError("window capture has no PNG image")
    width, height = struct.unpack(">II", header[16:24])
    if width < 10 or height < 10:
        raise RuntimeError("window capture has no usable dimensions")
    return [width, height]


def capture_allowed():
    """Whether this farm job may capture here: the farm's own reading of this
    Mac for the job (YAB_FARM_HAS, what its guard found the Mac meets, the
    Screen Recording checks of its job python and of a helper it starts
    among them), not a list of host names that missed each new Mac (m4 on
    2026-10-28, m2pro on 2026-11-08). adhd's raised blackout leaves outside
    capture refused there, and its pictures come from the previously
    authorized SCK recorder (picture() below), so a Mac that keeps that
    recorder may capture too."""
    if os.environ.get("YAB_FARM_WORKER") != "1":
        return False
    if "YAB_FARM_HAS" not in os.environ:
        # A farm runtime from before 2026-11-08 doesn't say: its old list.
        return os.environ.get("WHERE") in ("adhd", "renderer-2", "m2", "m2pro", "main", "m4")
    if "capture" in os.environ.get("YAB_FARM_HAS", "").split(","):
        return True
    return (os.environ.get("WHERE") == "adhd" or bool(os.environ.get("PROBE_CAPTURE_RECORDER"))) and _recorder().is_file()


def _recorder():
    return Path(os.environ.get("PROBE_CAPTURE_RECORDER", "/Users/dev/Documents/GitHub/fast-apps/farm-1620e700b76643a1/blackout-experiment/scfilm"))


def picture(pid, path, *, window_id=None):
    if not capture_allowed():
        raise RuntimeError("window capture must run through farm on a Mac the farm says may capture (YAB_FARM_HAS)")
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # macOS grants Screen Recording per executable, so a Mac keeps one
    # helper at a fixed path that was granted once (renderer-2, 2026-10-20);
    # one compiled into each job's folder is a new executable every time.
    kept = Path.home() / ".local/state/yab-farm/capture-tools/capture-window"
    helper = (Path(os.environ["PROBE_CAPTURE_HELPER"]) if os.environ.get("PROBE_CAPTURE_HELPER")
              else kept if kept.is_file() else path.parent / "capture-window")
    if os.environ.get("PROBE_CAPTURE_HELPER") and not helper.is_file():
        raise RuntimeError("configured capture helper is missing")
    if not helper.exists():
        subprocess.run(["swiftc", "-O", str(Path(__file__).with_suffix(".swift")), "-o", str(helper)], check=True)
    curtains = []
    if os.environ["WHERE"] == "adhd":
        for row in subprocess.check_output(["ps", "-Ao", "pid=,comm="], text=True).splitlines():
            parts = row.strip().split(None, 1)
            if len(parts) == 2 and parts[1].endswith("/blackout"):
                curtains.append(parts[0])
        if not curtains:
            raise RuntimeError("adhd blackout is not running")
    try:
        inspected = subprocess.run([str(helper), str(pid), str(path), str(window_id or 0), *curtains, "--metadata-only"], text=True, capture_output=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("window and blackout verification timed out after 10 seconds") from error
    metadata = {}
    if inspected.stdout.strip():
        metadata = json.loads(inspected.stdout)
        path.with_suffix(".occlusion.json").write_text(json.dumps(metadata, indent=2))
    if inspected.returncode:
        raise RuntimeError(inspected.stderr.strip() or inspected.stdout.strip())
    try:
        if os.environ.get("PROBE_CAPTURE_RECORDER_ONLY"):
            result = subprocess.CompletedProcess([], 1, "", "configured window recorder")
        else:
            result = subprocess.run([str(helper), str(pid), str(path), str(window_id or 0), *curtains], text=True, capture_output=True, timeout=10)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("ScreenCaptureKit still capture timed out after 10 seconds") from error
    if result.returncode and os.environ["WHERE"] != "adhd" and quartz_picture(metadata, path):
        metadata.update(capture="Quartz.CGWindowListCreateImage", denied_still_capture=result.stderr.strip())
    elif result.returncode:
        # Reuse the previously authorized, unchanged SCK recorder used in
        # blackout verification. No permission, signing or identity changes.
        stable = _recorder()
        if (os.environ["WHERE"] != "adhd" and not os.environ.get("PROBE_CAPTURE_RECORDER")) or not stable.is_file():
            raise RuntimeError(f"window capture exited {result.returncode}: {result.stderr.strip() or result.stdout.strip()}")
        frames = path.parent / (path.stem + "-sck")
        try:
            filmed = subprocess.run([str(stable), str(metadata["window"]), ".35", str(frames)], text=True, capture_output=True, timeout=10)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError("authorized SCK recorder timed out after 10 seconds") from error
        pictures = sorted(frames.glob("*.png"))
        if filmed.returncode or not pictures:
            raise RuntimeError("authorized SCK recorder: " + (filmed.stderr.strip() or filmed.stdout.strip()))
        shutil.copy2(pictures[-1], path)
        metadata.update(capture=os.environ.get("PROBE_CAPTURE_BACKEND", "ScreenCaptureKit"), recorder=str(stable), frames=len(pictures),
                        denied_still_capture=result.stderr.strip(), frame_times=str(frames / "times.json"))
    else:
        metadata = json.loads(result.stdout)
        metadata["capture"] = "ScreenCaptureKit"
    metadata["size"] = _size(path)
    path.with_suffix(".json").write_text(json.dumps(metadata, indent=2))
    return metadata


def quartz_picture(metadata, path):
    """The window through this python's own Screen Recording, when the
    helper swiftc built for this job has none. macOS grants Screen Recording
    per executable: a helper compiled fresh in each job's folder is a new one
    every time, and on renderer-2 every capture was refused with
    "The user declined TCCs" (-3801, 2026-10-20) while /usr/bin/python3,
    granted since 2026-10-03, captures the same window. Not on adhd, where
    blackout covers the screen and only window-level SCK sees under it."""
    window = (metadata or {}).get("window")
    if not window:
        return False
    try:
        import Quartz
    except ImportError:
        return False
    image = Quartz.CGWindowListCreateImage(
        Quartz.CGRectNull, Quartz.kCGWindowListOptionIncludingWindow, int(window),
        Quartz.kCGWindowImageBoundsIgnoreFraming | Quartz.kCGWindowImageBestResolution)
    if image is None or Quartz.CGImageGetWidth(image) < 10:
        return False
    url = Quartz.CFURLCreateWithFileSystemPath(None, str(path), Quartz.kCFURLPOSIXPathStyle, False)
    destination = Quartz.CGImageDestinationCreateWithURL(url, "public.png", 1, None)
    Quartz.CGImageDestinationAddImage(destination, image, None)
    return bool(Quartz.CGImageDestinationFinalize(destination))


def app_picture(path, ask, capture_error):
    """A native view rendering for chrome review, without OS screen capture."""
    if "blackout is not" in str(capture_error):
        raise RuntimeError(str(capture_error))
    path = Path(path)
    result = ask({"do": "winshot", "path": str(path)})
    size = _size(path)
    metadata = {"capture": "native-app-view-rendering", "screen_capture_error": str(capture_error),
                "limit": "This picture reviews native chrome; it does not verify ScreenCaptureKit frames or blackout occlusion.",
                "size": size, "result": result}
    path.with_suffix(".json").write_text(json.dumps(metadata, indent=2))
    print("  ScreenCaptureKit unavailable; saved native chrome rendering:", path, flush=True)
    return metadata
