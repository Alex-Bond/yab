# Security

A browser holds people's sign-ins, passwords, mail and money. Please report anything that could expose them privately, so it can be fixed before it is public.

## How to report

Use GitHub's private reporting: **[Report a vulnerability](https://github.com/yetanotherbrowser/yab/security/advisories/new)** (the Security tab of this repository, then "Report a vulnerability"). Only the maintainers see it.

If you can't use GitHub, write to **security@yetanotherbrowser.com**.

Please include:

- the Yab version (Yab menu › About Yab) and macOS or iOS version;
- the engine of the tab (WebKit or Chromium), if a page is involved;
- steps to reproduce, and a page or file that shows it, if you have one;
- what an attacker gains.

Never open a public issue, pull request or discussion about a vulnerability, and never test against other people's accounts or data.

## What happens next

- We confirm we have your report within 3 working days.
- We tell you whether we can reproduce it and how serious we think it is within 10 working days.
- We fix it in a private branch, release it, and then publish the advisory, crediting you unless you'd rather not be named.
- We aim to release a fix for a critical issue within 14 days of confirming it.

## In scope

The Mac app, the iPhone app, the sync server (`sync-server/`), the update path (feed, download, signature check), page scripts, extensions support, the agent and MCP features, and anything in this repository.

Bugs in WebKit or Chromium themselves belong upstream (Apple's and the Chromium project's own programs), unless Yab makes them reachable where they otherwise would not be. Findings that need a compromised Mac, or physical access to an unlocked one, are usually out of scope.
