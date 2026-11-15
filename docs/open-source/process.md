# From bug report to release

How a problem someone hits in Yab becomes a fix in their hands, who does each step, and how maintainers and their coding agents share one queue.

## The path

```text
report ─▶ triage ─▶ ready ─▶ fix PR ─▶ CI ─▶ maintainer review ─▶ merge ─▶ release ─▶ closed with version
```

### 1. Report

Bugs reach the queue three ways, and all three end up as GitHub issues:

- **GitHub issue forms** (`.github/ISSUE_TEMPLATE`): bug, crash, feature request. The forms ask for what triage needs: Yab version, device, macOS or iOS version, the tab's engine, area, steps, expected and actual.
- **Help › Send Feedback** inside Yab. Feedback goes to the maintainers' feedback inbox first, because it can hold private details (email, diagnostics, screenshots of someone's tabs). A maintainer or the feedback bridge turns a bug in it into an issue with the private parts left out, and links the two.
- **Crash reports** the app sends after a crash (only with the person's yes). Grouped by signature; a group that keeps happening gets one issue.

Security reports never become public issues: they go through a private advisory ([SECURITY.md](../../SECURITY.md)) and are published after the fix ships.

### 2. Triage

A maintainer reads every new issue by hand, about once an hour during the working day. Nothing labels or answers issues automatically. The maintainer:

- **Arc first.** Yab does things the way Arc does ([CONTRIBUTING.md](../../CONTRIBUTING.md#product-conventions)). A request to behave differently from Arc gets `arc-divergent` and is closed as not planned, with a note that it reopens once 10 people have voted for it or reported it. At 10 it reopens and ships as a setting, off by default. A place where Yab differs from Arc by accident is a bug;
- adds one or two `area: …` labels (the register's themes), an engine label when it is engine-specific, and one severity: **Blocker**, **Broken**, **Annoying** or **Polish**;
- adds `needs info` with a short comment when the version, OS or steps are missing, and looks again when the reporter replies;
- marks `duplicate` with a link when an existing issue describes the same thing, and closes it.

When the labels are set and nothing is missing, `needs triage` comes off, and the maintainer marks the issues that are ready to work on:

- `help wanted`: understood, reproducible, open to anyone;
- `good first issue`: also small and contained;
- `needs design`: changes what people see; the owner picks from pictures first, then it becomes `help wanted`;
- `proposal`: a feature; the owner decides ([GOVERNANCE.md](../../GOVERNANCE.md)).
- `arc-divergent`: closed as not planned until 10 people ask; a maintainer reopens it at 10 (count 👍 on the issue and its duplicates).

Severity sets the order: Blockers before everything, then Broken, Annoying, Polish. Within a severity, the issue with the most reports and 👍 goes first.

### 3. Fix

Anyone can take a `help wanted` issue by commenting on it. Whoever takes it, person or agent, works on a branch and opens a pull request that says `Fixes #N` and carries the proof [CONTRIBUTING.md](../../CONTRIBUTING.md#making-a-change) asks for: a failing-then-passing test for logic, before and after pictures for anything visible, numbers for speed.

### 4. CI

**CI** (`.github/workflows/ci.yml`) runs on every pull request, forks included, on GitHub's macOS runners: the parse and design checks on the changed lines, the app build (signed ad hoc), the MailCore tests and the test suites that cover the changed files. The whole `swift test` runs on `main` as an advisory job until it finishes on a clean Mac. CI runs the pull request's code with no secrets and a read-only token.

There is no automatic review: no bot comments on pull requests or issues.

The maintainers' build farm is not involved. It never runs code from a pull request.

### 5. Maintainer review and merge

A human merges, always:

1. CI is green. Branch protection requires it.
2. A maintainer reads the diff and the proof by hand, about once an hour during the working day, checking the same things [CONTRIBUTING.md](../../CONTRIBUTING.md#making-a-change) asks for: the root cause rather than a patch, behavior that stays Arc's unless an `arc-divergent` issue reached 10, proof that matches the change, the design system, the menu and Settings completeness rules, privacy, and wording. For a bug that only shows on the released Chromium engine (patched CEF) or in a reporter's particular setup, the maintainer runs it on their own Macs and says what they checked.
3. A code owner approves (`.github/CODEOWNERS`; branch protection requires one approving review from a code owner, and a new push dismisses an old approval).
4. The maintainer squash-merges. The squash message's first line becomes the release note's line, so it says what changed for people using Yab.

A maintainer may push small fixes to a contributor's branch (with "Allow edits by maintainers") rather than ask for another round.

### 6. Release

Releases are cut from `main` on the owner's go, on the maintainers' Macs (signing, notarization and the patched CEF build live there, not in GitHub). Each release:

- adds its lines to the release notes, newest first, which feeds the in-app "What's new", the site's changelog and the appcast;
- goes to the Nightly channel first and to Stable after it has run clean;
- closes the issues it fixed, or comments on already-closed ones, with the version that has the fix, and adds `fixed in release`.

Say "fixed" only once the reporter's scenario has passed on a built app. A merged pull request alone is "fix merged, not yet released".

## Agents and maintainers on one queue

The maintainers run coding agents (Claude Code, Codex) on the same issues contributors see. To keep everyone from doing the same work twice:

- **The issue is the lock.** Before starting, a person comments "I'm on it"; a maintainer's agent session adds `agent: fixing` and comments with the branch it works on. Nobody starts on an issue that has either, unless it has been quiet for a week and they ask first.
- **Agents open pull requests like anyone else.** Same template, same proof, same CI, same maintainer review. They never merge, never close a human's issue, and never mark something fixed without proof. Their pull requests say they were written by an agent.
- **Humans first for `good first issue`.** Agents leave those to newcomers.
- **Agents take the long tail.** Blockers get a maintainer's attention at once. Broken and Annoying bugs with clear steps and no taker after a few days are fair game for an agent.
- **One review step for all.** A maintainer reviews an agent's pull request with the same care as a stranger's, and a contributor's with the same speed as an agent's.

The maintainers' internal request register (a database of every report, its reporters and what they were told) stays private, because it holds people's contact details. Its rows link to the public issue, and the issue is where the public state lives.

## Setting it up

What the owner adds or changes before the repository goes public. Nothing here is done yet.

### Secrets

None. CI builds and signs ad hoc. No signing certificate, notarization credential, API key, farm address, ssh key, Neon, Blob or site token goes into GitHub.

### Repository settings

- **Actions › General › Fork pull request workflows from outside collaborators:** "Require approval for all outside collaborators". A maintainer presses Approve before a newcomer's workflows run.
- **Actions › General › Workflow permissions:** "Read repository contents" by default (each workflow asks for the little more it needs).
- **Actions › Runners:** no self-hosted runners on this repository or its organization's public runner groups, ever.
- **Branches › main:** a ruleset requiring a pull request, 1 approving review from a code owner, dismissal of stale approvals on new pushes, the status checks "Parse and design checks", "Build Yab Dev" and "Swift tests", linear history, and no force pushes.
- **Code security:** enable private vulnerability reporting, Dependabot alerts, and secret scanning with push protection.
- **General:** allow squash merging only; enable "Always suggest updating pull request branches"; enable Discussions if wanted.
- **Labels:** run the "Labels" workflow once (Actions › Labels › Run workflow) to create everything in `.github/labels.yml`.

### Addresses

`SECURITY.md` and `CODE_OF_CONDUCT.md` name `security@yetanotherbrowser.com` and `conduct@yetanotherbrowser.com`. Create both, or change the files to addresses that exist.

## Assumptions to check before going public

These docs were written before the public tree was settled. Check each:

- **Repository address.** Links use `github.com/yetanotherbrowser/yab`. If the public repository lives elsewhere, replace it everywhere: `git grep -l yetanotherbrowser/yab`.
- **License.** Apache-2.0 (`LICENSE`, `NOTICE`); names and marks are reserved in `TRADEMARKS.md`; third-party code and the Central Icons are in `THIRD_PARTY_NOTICES.md`.
- **What stays private.** The docs assume these are left out of the public tree or kept but unused by contributors: the farm (`farm`, `mini`, `adhd`, `runs`, `stage`, `scripts/remote`, `scripts/release`, `scripts/stand`, `docs/farm*.md`), release scripts (`release.sh`), the maintainers' agent rules (`AGENTS.md`, `CLAUDE.md`, `Phone/AGENTS.md`), plans and results at the root (`PLAN-*.md`, `RESULT-*.md`, `HANDOFF-*.md`), `docs/requests.md` and other docs naming reporters, `evidence/` and `docs/evidence/`, and the provisioning profile. `CONTRIBUTING.md` links to `Phone/AGENTS.md`; drop that link if the file is excluded.
- **Screenshots.** `docs/images/readme/` holds two pictures from the site's published posts. Replace them with fresh ones of the current release if the look has moved on.
