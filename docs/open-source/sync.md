# How the public repository is kept current

Yab is developed in a private repository. The public repository receives the
source of every release: when a release is published, the source of the
released commit is exported and committed to the public `main` as one commit.

## What a sync does

`scripts/open-source/sync.sh --ref COMMIT [--push]`:

1. Exports the commit with `export.sh`: the same paths left out
   (`exclude.txt`), the same rewrites (`scrub.tsv`), the same public files
   (`overlay/`), and the same scan (gitleaks over files and history, personal
   data, forbidden files, the word list with its allowlist, the license gate).
   A scan that is not clean stops the sync before anything is pushed.
2. Clones the public `main` into a new folder.
3. Refuses if the public `main` has commits that a sync did not make. A
   pull request merged on the public side is first ported into the private
   repository; otherwise the next sync would replace it.
4. Replaces the clone's tree with the export's and commits it with a
   `Private-Commit: <sha>` trailer, so each public commit names the release
   commit it came from. With `--push` it pushes; without, it stops there (a
   dry run) and prints where the commit waits.

It never rewrites history and never force-pushes. Each run writes a new
`~/yab-sync-<stamp>` folder; after a push it keeps the newest three.

## When it runs

`release.sh` starts it in the background right after a release is published
and the register is updated, with `--ref` set to the released commit and
`--push`. It runs once per release (for a release split into halves, after the
arm64 half). It never fails or holds a release: its output goes to
`~/Library/Logs/yab-open-source-sync-<version>.log`, and a refused scan or
push only shows there. `YAB_OPEN_SOURCE_SYNC=0 ./release.sh` skips it.

When a sync was refused, read the log, fix the cause on the release line
(a new name for the word list's allowlist, a path for `exclude.txt`, a
rewrite for `scrub.tsv`, or the source itself), and run it again by hand:

    scripts/open-source/sync.sh --ref v<version>            # dry run
    scripts/open-source/sync.sh --ref v<version> --push

A later release's sync carries everything before it, so a skipped one is
caught up by the next.

## Rehearsal

`--public PATH` points the sync at a local clone or bare copy of the public
repository instead of GitHub, which is how a change to the export is tried
without pushing anywhere.
