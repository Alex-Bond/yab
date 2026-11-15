# Spaces missing after an update

Request 1070 (October 24, 2026): after updating to 0.36, every tab of 10+
spaces was gone. The reporter's profile was not available; this page is
what the code and the update matrix establish, what Yab now repairs by
itself, and what a person can do by hand.

## What can hide every space but Personal

- `Spaces.read()` read `spaces.json` as one array: a single space that
  failed to decode (a malformed look, a truncated or missing file) made the
  whole list empty, Personal came up alone, and the next save
  (`Browser.restoreInitialRow()` through `keepPaint()`) wrote Personal alone
  over the index. Every other space's row, `session-<UUID>.json`, stayed on
  disk with all its tabs, but nothing listed it any more.
- With sync on, that Personal-only list is then the Mac's: `SyncCenter.tell()`
  reconciles the journal to it and the other devices delete the missing
  spaces, rows and all (`SyncCenter.adopt()` through `deleteSpace()`). On
  another Mac that is real erasure, not hiding.
- The preferences gone while the folder stays (an uninstaller sweeping
  `~/Library/Preferences`, feedback #320): Spaces came up off and only
  Personal was reachable. Since 0.35.9 kept spaces turn them back on.

Nothing in the session format changed between 0.34.7 and 0.36.3: same file
names, same envelope, only optional fields added. An ordinary update does
not touch these files (the matrix below). What damaged the reporter's index
is not known.

## What Yab does now

- `SpaceRecovery.read` (Sources/Fast/SpaceRecovery.swift) runs only when
  the index is missing or does not decode. It first copies the unreadable
  index aside, byte for byte, as `spaces.unreadable-<UUID>.json`, and
  `Spaces.write` never overwrites an undecodable index without that copy.
- Spaces that still decode one by one keep their id, name, icon and
  sign-in choice; a bad look is dropped, not the space.
- A space with a saved, non-empty row and no readable entry comes back as
  "Recovered Space <last six of its id>", with sign-ins of its own (its own
  store, if it had one, still holds its cookies; a space that shared
  Personal's sign-ins needs signing in again).
- A valid list is never second-guessed, an empty one included. Mail, the
  shared pins, window rows and spaces deleted within the last minute (still
  undoable) are never brought back.
- `Spaces.on` counts a damaged list's rows, or another space's row on disk,
  so a repaired profile with its preferences gone still has Spaces on.

## Recovering by hand

Everything Yab keeps is in `~/Library/Application Support/Yab` (before
October 2026, `~/Library/Application Support/Fast`).

1. Quit Yab and copy the whole folder somewhere safe before trying anything.
2. Look at what is there:
   - `spaces.json`: the list of spaces. If it names only Personal while
     other rows exist, the list was overwritten.
   - `session.json` is Personal's tabs; `session-<UUID>.json` each other
     space's, with every URL, pin, kept tab and folder.
     `session-window-*.json` are the rows of windows other than the first.
   - `*.unreadable-*.json`: files Yab could not read and set aside rather
     than overwrite. A `spaces.unreadable-*.json` is the old list.
   - `Sync Snapshot/`: spaces, rows and bookmarks from before this Mac
     joined sync. Settings › Sync offers Undo Joining for a week.
3. With a build that has this repair: quit Yab, move `spaces.json` out of
   the folder (keep it), and open Yab. Every space with a saved row comes
   back, as "Recovered Space …" where its name is unknown. Rename them, and
   in Settings › Spaces set sign-ins back to shared where they were. If a
   `spaces.unreadable-*.json` is there, put it back as `spaces.json`
   instead: the repair keeps every name it can read from it.
4. With sync on, turn it off on this Mac before step 3, so a Personal-only
   list cannot reach the other devices, and check another Mac's folder: its
   rows may still be whole.
5. If the rows themselves are gone, the tabs are only where a copy was kept:
   Time Machine, `Sync Snapshot/`, another device, or the browser they were
   brought in from (Arc's `StorableSidebar.json`). History (⌘Y) still has
   every page that was opened.

## The update matrix

`evals/update-spaces/job.sh` builds 0.34.7, 0.35.5 and 0.35.18 at their
release commits, lets each one write a 12-space profile of 288 tabs (48
pins, 96 kept tabs in folders, 144 of today's, 12 pairs, a third of the
spaces with their own sign-ins), and opens a copy of it in 0.36.0, 0.36.3,
main as it was and the repaired build, each three ways: the settings kept,
only the defaults (Tidy and pins as a Mac that never opened Settings), and
the preferences gone. Every space is visited and every row read back. Then
a malformed look, a truncated index and a missing index, main against the
repaired build, which must show all 12 spaces, keep every tab and the
damaged original, and read the same after another launch.

October 24 (farm `bfe024a29e07415a`): all 27 updates kept 12 spaces and
288 tabs, ids, URLs, pins, folders and pairs included; the repaired build
showed all 12 spaces in the three damaged cases, and again after a
relaunch. Main before the repair (farm `6f47bd4974b840ce`, `0946349e`)
showed 1 space of 12 in each damaged case, the 288 tabs left on disk.
`PREV=JOB` reuses an earlier job's built apps.

`evals/golden/spaces_update.py APP` runs the three damaged-index cases on
a built app; it is in the release gate. Both need `./farm exec --display`.
Results: `docs/evidence/spaces-update-2026-10-24.json`.
