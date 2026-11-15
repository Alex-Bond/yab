---
name: linear
description: Linear issues, inbox, projects and its keyboard-driven editing.
sites: [linear.app, linear.new]
keywords: [linear, issue, cycle, triage, linear project]
action: Plan this issue | /*/issue/* | Read this issue and its comments and propose a short plan: the steps, open questions, and what to ask whom. Don't change the issue.
item: Issue | in: page | anchor: button[aria-label="Copy issue URL"] | place: before | style: clone | icon: 14 / 1.3 | title: [aria-label="Issue title"] | button: Plan
action: Plan this issue | @Issue | Read this issue and its comments and propose a short plan: the steps, open questions, and what to ask whom. Don't change the issue.
action: Do What It Asks | @Issue | Read this issue and its comments, work out what is asked of the user and do the parts you can in their signed-in tabs, stopping before anything that sends, posts, pays or deletes. Don't change the issue; finish with what you did and what is left for them.
---

# Linear

## URLs

- New issue: `https://linear.new` or `https://linear.app/new`
- New issue for a team: `https://linear.app/team/${teamKey}/new`
- Prefilled: add `?title=${title}&description=${markdown}` to either new-issue URL
- Issue: `https://linear.app/${workspace}/issue/${issueKey}` (the slug after it is optional)
- Inbox: `https://linear.app/${workspace}/inbox`
- My issues: `https://linear.app/${workspace}/my-issues`

`${workspace}` is the URL slug of the user's workspace; take it from any Linear tab or from memory.
For existing work, reuse links from the page; don't compose deep project URLs.

## Reading

- An issue page: `text` gives title, description, sub-issues and the activity/comment stream.
- Properties (status, assignee, priority, labels, project, cycle) are buttons in the side panel.
  `Meta+i` toggles that panel on project pages.
- Lists are virtualized; for long views, filter first (`f` opens the filter menu) and then read.

## Editing an issue (issue open, focus not in a text field)

- `s` status, `a` assignee, `i` assign to me, `p` priority, `l` labels, `Shift+p` project.
- Each opens a small command list. `type` the value into it and `press` Enter, or click the option by
  ref. Snapshot after; the panel updates in place.
- `e` edits the title and description in place.
- Comment box at the bottom; `Meta+Enter` submits. Comments with @mentions notify people and Yab asks
  before sending.

## Creating

- `c` opens the composer anywhere; `v` makes it fullscreen.
- Fill the title, then the description, then set team, status and assignee from the chips at the
  bottom. `Meta+Enter` creates it, which goes through the user's yes.
- The prefilled `linear.new` URL is the quickest route when you already know the text.

## Getting around

- `Meta+k` command menu: nearly every action and every issue by key or title.
- `/` search, `o` then `i` open an issue, `o` then `d` project documents, `g` then `i` inbox.
- `Meta+f` searches within the current view.

## Inbox

`j` / `k` move, Enter opens, `h` snoozes, `Shift+s` unsubscribes from the issue, Backspace deletes
the notification (not the issue). Ask before clearing a lot at once.

## Pitfalls

- Single-letter keys do nothing while the caret is in a field; `Escape` first.
- Several workspaces are possible; the switcher is at the top left. Check which one before creating.
