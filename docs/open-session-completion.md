# Finish the open Claude Code work

Status: non-onboarding work committed to local `main` as `77e0bb3`, 2026-09-28. Preserve the other sessions' worktrees and unrelated changes. `origin/main` remains behind and was not pushed.

Onboarding is being handled in another chat. Do not change or verify it here.

## Work and acceptance checks

1. **AI command models.** Review `d77dabd` in `.claude/worktrees/command-models`, bring its per-command model and effort choices into `main`, and reconcile them with the current agent settings. Check defaults, subscription availability, built-in commands, persistence, and execution through both Claude Code and Codex. The Raycast reference screenshots are already in Test chat 12; another screenshot must not gate the code.
2. **Measure.** Finish the implementation started in Test chat 13's `scratchpad/w`. Confirm element hover and selection, rulers/guides, zoom and dark mode, Copy for Agent, the keyboard/menu entry, and exit behavior on non-local pages. Review its untracked `Measure.swift` and `evals/devmode` checks before transfer.
3. **Folder preview.** Finish Test chat 1's hover/search card from `scratchpad/fp`. Check keyboard navigation, opening a tab, dismissal, small windows, and the existing folder and agent-folder states. Preserve the folder color and face work already in `main`.
4. **Link routes.** Review Test chat 16's remaining changes. Cover the suggestion rule, Always Open menu, Add Site, deleting a route or space, path matching, privacy, and opening without a small window. Transfer only fixes still needed by `main`.
5. **Final verification.** Build and test on this Mac first, per `AGENTS.md`; use `adhd` only if another build, test, or measurement occupies it. Run targeted Swift tests, `./design-check`, and the relevant native end-to-end flows. Inspect the running build and captured frames for the UI work. Record commands, results, and any remaining blocker below. Recheck `git status` and preserve all unrelated work.
6. **Latest UI feedback.** Make the local address's host, path, and port use a consistent type size; match the tab's port to its title. Narrow the closed-folder preview and move it close to its folder, using Arc as a visual reference. Confirm both in the running app at normal and small window sizes.
7. **Command defaults.** Keep five common text commands enabled for new users: Improve writing, Fix spelling and grammar, Translate, Summarize, and Explain simply. Keep the other built-ins available but disabled by default. Preserve existing users' saved switches and custom commands. Verify a fresh profile and a saved profile.
8. **Reconcile the earlier visual sessions.** Test chat 5's colored folders are in `2861b94` and `0f3d71b`; Test chat 6's peek morph is in `9d5ca69` with measured open/close CPU and no dropped frames; Test chat 2 completed the Tidy concept and effect in `1955aab`. Test chat 4 and 7 duplicate that finished Tidy work. Confirm these commits and their evidence before treating the stalled chats as open engineering work.

## Evidence log

| Item | Result |
| --- | --- |
| Initial `main` | `506f91e`, clean; 205 commits ahead of saved `origin/main` |
| AI command models | Model selection and effort persisted after reopen in `codexfinish`; Explain simply ran through Yab on GPT-6 Luna and returned a preview without changing the field; direct Codex GPT-6 Luna/high request returned `OK`; Claude Code signed in but a live request hit its weekly limit |
| Measure | Native fixture check: 23 checks passed; 300 hovers median 0 ms, p95 1 ms, max 1 ms |
| Folder preview | 240 pt wide, 4 pt offset; searched, picked, and inspected at 1100×720 and 640×452; final PNGs in `docs/evidence/open-sessions-20260927/` |
| Link routes | Native external link from Personal to a local-site route opened in Work as a full tab; `/other` stayed Personal with a path route, while `/special/abc` opened in Work; route settings render verified |
| Onboarding | Out of scope by the user's request; owned by another chat |
| Command defaults and local address | Fresh profile's selection list contains exactly the five chosen commands; saved profile retained its 17 previous switches. Address and tab port checked in running build; screenshot in evidence folder |
| Colored folders, peek, and Tidy | Commits `2861b94`, `0f3d71b`, `9d5ca69`, `1955aab` in `main`; no transfer needed |
| Final verification | `./build.sh` passed twice, including signed build `202609272340` with the compact result-card label change. `./design-check`, staged `git diff --check`, Measure's 23 native fixture checks, and native folder/route/address checks passed. Targeted Swift tests reached 168/179 build steps, then Swift's driver stalled in macOS `getxattr` and was stopped; no test result is claimed. An `adhd` check previously required Tailscale authorization. |
