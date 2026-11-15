<!--
Thanks for the fix. Fill in each section; a pull request without proof waits.
CONTRIBUTING.md explains what proof each kind of change needs.
-->

## What changes

<!-- One or two sentences, in terms of what someone using Yab notices. -->

Fixes #

## Why it happened

<!-- The root cause. If you added a retry, a delay or a timer, explain why the
cause itself can't be fixed instead. -->

## Proof

<!-- Pick what applies and delete the rest. -->

- [ ] **Logic:** a test that fails on `main` and passes here: `swift test --filter ...`
- [ ] **Visible change:** before and after screenshots or recordings below, same window size and theme
- [ ] **Performance:** numbers before and after, same Mac, same method
- [ ] **Docs or copy only:** no proof needed

| Before | After |
|---|---|
|  |  |

## Checked on

- Yab Dev built from this branch on macOS:
- Engine(s) tried: WebKit / Chromium (stock CEF) / not about a page

## Checklist

- [ ] `swift test` passes (or the suites this touches: list them)
- [ ] `./design-check --head` is clean, or each exception says why with `// design:`
- [ ] Anything that changes how Yab looks was approved in the issue first
- [ ] A new menu item is also a command in the field; a new Settings row is classified in `NativeActions.swift`
- [ ] Words on screen and in docs are American English, with no em dashes
