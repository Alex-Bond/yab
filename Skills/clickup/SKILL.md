---
name: clickup
description: ClickUp tasks, views, inbox and the command bar.
sites: [app.clickup.com, clickup.com]
keywords: [clickup, task, list, sprint, clickup inbox]
---

# ClickUp

## URLs

- Sign in: `https://app.clickup.com/login` (the sign-in itself is a `handoff`)
- Task: `https://app.clickup.com/t/${taskId}`
- Task by custom id: `https://app.clickup.com/t/${workspaceId}/${customId}`

Everything else (spaces, lists, views) has long numeric URLs. Take them from the tab you are on or
from a link the user gave; don't guess.

## Working style

- Stay in the tab you signed in with; ClickUp keeps state per session.
- If a link tries to open the desktop app instead of the page, the "Detect Desktop App" setting is on.
  Tell the user rather than changing their settings.
- Jump with the command bar instead of walking the sidebar: `press` `Meta+k` (or `s`), type a task,
  list or doc name, pick the result by ref.
- Views are keyed: `l` list, `b` board, `c` calendar, `x` team, `h` home, `i` inbox, `d` dashboards.
  Single-letter keys only work when focus is not in a text field; press `Escape` first if unsure.

## Reading

- A list or board shows task names, status, assignees and dates as rows or cards. Long lists load as
  you scroll; `scroll` and snapshot again.
- Open a task to see everything: description, custom fields, subtasks, activity. Use `text` for
  long descriptions and comment threads.

## Editing a task (task open)

- Status `Shift+s`, assignee `Shift+a`, assign to me `m`, due date `Shift+d`, priority `Shift+p`,
  subtask `Shift+t`, comment `Shift+m`, timer `Shift+.`.
- Each opens a picker; snapshot, then click the option by ref.
- `Escape` closes the task.
- New task: `t`, fill the name, Enter.

## Inbox

- Tabs: `Shift+a` all, `Shift+p` primary (older ClickUp: `Shift+i` important), `Shift+o` other,
  `Shift+z` snoozed, `Shift+c` cleared.
- `j` / `k` next and previous, `o` or Enter opens, `]` toggles the details sidebar, `Space` refreshes.
- `e` clears (or restores), `z` snoozes, `u` toggles read. Ask before clearing a whole inbox.

## Pitfalls

- Comments that @mention people notify them; Yab asks before sending.
- Deleting tasks or lists goes through the user's yes.
- Several workspaces are common; the name is at the top left. Check memory before creating tasks.
