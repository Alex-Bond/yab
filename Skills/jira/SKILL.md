---
name: jira
description: Jira Cloud issues, JQL search, boards and list-view triage.
sites: [atlassian.net]
keywords: [jira, ticket, issue, JQL, sprint, backlog, epic]
action: Plan this issue | /browse/* | Read this issue and its comments and propose a short plan: the steps, open questions, and what to ask whom. Don't change the issue.
---

# Jira Cloud

Jira and Confluence share `${site}.atlassian.net`. Paths under `/wiki` are Confluence (see that skill).
Check memory for the user's `${site}` and their project keys.

## URLs

- Your work: `https://${site}.atlassian.net/jira/your-work`
- Issue: `https://${site}.atlassian.net/browse/${issueKey}`
- JQL results: `https://${site}.atlassian.net/issues/?jql=${urlEncodedJql}`
- Board: `https://${site}.atlassian.net/jira/software/projects/${projectKey}/boards/${boardId}`

If you know the key (ABC-123), go straight to `/browse/${issueKey}`. Menus are the slow way.

## JQL you will use

- Mine and open: `assignee = currentUser() AND statusCategory != Done ORDER BY updated DESC`
- Recently changed in a project: `project = ABC AND updated >= -7d`
- Current sprint: `project = ABC AND sprint in openSprints()`
- Text: `text ~ "login timeout"`
- Reported by me: `reporter = currentUser()`

URL-encode the query. The results page has a list view that reads cleanly in a snapshot; `text` gives
the rows as lines.

## Reading an issue

`text` on `/browse/${key}` gives summary, fields, description and comments. Fields (status, assignee,
priority, sprint, labels) are also labeled controls in the snapshot sidebar. Linked issues and
subtasks appear as keys you can open the same way.

## Changing an issue

- Status: the status button near the title opens transitions; pick one by ref. Some transitions open
  a screen with required fields.
- Assign: `a`, or `i` to assign to yourself (the signed-in user).
- Comment: `m` focuses the comment box; `type`, then Save. Yab asks before it goes out when it
  notifies people.
- Other fields: click the field, edit, press Enter. Re-snapshot after each change; the panel
  re-renders.
- `.` opens quick actions for the current issue.

## Triage in list view

`j` / `k` move, `o` opens, and many cells edit inline. On a board, `n` / `p` move between columns.
Dragging cards is not possible with refs; change the status field instead.

## Creating

`c` opens the create dialog. Confirm project and issue type first, then summary and description.
Create makes Yab ask the user.

## Keys

`/` quick search (`/` then Enter for advanced search), `Meta+k` command palette, `?` all shortcuts.

## Pitfalls

- Single-letter keys fire only when focus isn't in a field; `Escape` first.
- SSO and sign-in: `handoff`.
- Deleting issues or bulk changes wait for the user's yes.
