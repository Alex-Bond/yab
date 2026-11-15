# How decisions are made

## Roles

- **Owner.** Serafim Korablev started Yab and has the final word on what it is: its look, its scope, its releases, and who maintains it.
- **Maintainers.** People with merge rights, listed in [.github/CODEOWNERS](.github/CODEOWNERS). They triage issues, review and merge pull requests, and cut releases when the owner asks.
- **Contributors.** Anyone who reports a bug, answers a question, reviews a change or sends a pull request.
- **Agents.** Coding agents (Claude Code, Codex) that maintainers run by hand. They may open fix pull requests like anyone else, but never merge, release, label or close issues on their own. Nothing in the repository runs an agent automatically.

## How a change gets in

1. Bugs: a fix with proof (see [CONTRIBUTING.md](CONTRIBUTING.md)) is reviewed by one maintainer and merged. No discussion needed beyond the pull request.
2. Anything people see (layout, motion, controls, words on screen) is decided by the owner from pictures before it is built. Open an issue with a mockup or screenshots; the owner picks.
3. New features, new settings, and changes to what Yab collects or sends start as an issue labeled `proposal`. The owner says yes, no, or "not now" there, with a reason.
4. Yab follows Arc's behavior. A request to diverge from it waits until 10 people ask, then ships as an option with Arc's way as the default ([CONTRIBUTING.md](CONTRIBUTING.md#product-conventions)).
5. Disagreements between maintainers go to the owner, whose call is final.

## Releases

Maintainers release from `main` on the owner's go. Each release lists its changes in the [changelog](https://yetanotherbrowser.com/changelog), and fixed issues are closed with the version that fixed them. See [docs/open-source/process.md](docs/open-source/process.md).

## Becoming a maintainer

Several merged, well-proven pull requests and helpful reviews over a few months. The owner invites people; you can also ask.

## Changing this page

By pull request, merged by the owner.
