---
name: asana
description: Asana My tasks, inbox, projects and the task details pane.
sites: [app.asana.com, asana.com]
keywords: [asana, task, my tasks, project, subtask]
---

# Asana

## URLs

- Home: `https://app.asana.com/0/home`
- Inbox: `https://app.asana.com/0/inbox`
- My tasks: `https://app.asana.com/0/my_tasks`
- Task (classic form): `https://app.asana.com/0/${projectId}/${taskId}`

Newer links look like `https://app.asana.com/1/${workspaceId}/project/${projectId}/task/${taskId}`.
Both work; reuse whatever link the user or the page gives you rather than composing one.

## Sign-in

A redirect to `/-/login?u=...` means the session is gone. `handoff` for the sign-in; the encoded `u`
brings the user back to where you were, so wait on that same tab afterwards.

## Finding work

- "What's on my plate": My tasks is the right default. Sections (Recently assigned, Today, Upcoming,
  Later) are headings in the snapshot; due dates sit beside each task name.
- Search: `press` `Tab+/` to focus it, or click the search box by ref, type and read the results.
- Inbox: items are notifications about tasks; `j` / `k` move between them, and `e` archives the
  selected one. Archiving is reversible but check the user wants it.

## Working on a task

Clicking a task opens the details pane on the right and leaves the list in place. The pane updates
in place, so snapshot again after opening each task. In the pane:

- Assignee, due date, projects and custom fields are labeled buttons; click, then pick from the
  popover.
- Description and comments are rich text fields. Use `text` to read long threads.
- Keyboard, with the pane focused (Tab is held as a modifier): `Tab+m` assign to me, `Tab+d` due date,
  `Tab+c` comment, `Tab+s` subtasks, `Tab+p` add to project, `Tab+f` collaborators.
- Mark complete with the "Mark complete" button; it is reversible.
- `Escape` closes the pane.

## Creating

- `Tab+q` opens quick add anywhere. In a list, `Enter` on a task adds one below it and `Shift+Enter`
  one above; `Tab+n` starts a new section.
- Posting a comment that mentions people notifies them; Yab asks before it is sent.

## Pitfalls

- If a `Tab+` chord does nothing, focus is probably in a text field; press `Escape` first, or use the
  visible button.
- Several workspaces are common. The workspace name sits at the top of the sidebar; check memory and
  that name before creating anything.
- Deleting a task makes Yab ask the user.
