---
name: trello
description: Trello boards, lists, cards, the inbox and search.
sites: [trello.com]
keywords: [trello, board, card, kanban]
---

# Trello

## URLs

- Home: `https://trello.com/`
- Cards assigned to me: `https://trello.com/u/my/cards`
- Board: `https://trello.com/b/${boardShortLink}/${slug}`
- Card: `https://trello.com/c/${cardShortLink}/${slug}`
- Search: `https://trello.com/search?q=${query}`
- Shortcuts: `https://trello.com/shortcuts`

The short link is the stable part; the slug is decoration. Reuse links from the page or the user.

## Reading a board

- `text` on a board gives lists in order with their card titles, which is usually all you need.
- For the raw data, the board or card URL with `.json` added
  (`https://trello.com/b/${boardShortLink}.json`) returns everything as JSON while signed in: labels,
  members, due dates, checklists. `text` it. Good for big boards.
- Open a card by clicking it; the card dialog has description, checklists, labels, members, dates and
  activity. `Escape` closes it.

## Search operators

`@me`, `member:${name}`, `board:${name}`, `list:${name}`, `label:${name}`, `due:week`, `due:overdue`,
`is:open`, `is:archived`, `has:attachments`, `created:7`, `edited:7`.

## Changing cards

- Moving a card between lists: dragging isn't possible with refs. Open the card and use its Move
  action, pick board, list and position, confirm.
- Title: `t` on a hovered or open card, or click the title in the dialog.
- Labels, members, dates, checklist items: the buttons in the card dialog, then pick by ref.
- New card: the "Add a card" button at the bottom of a list, type the title, Enter.
- Archive: the card's Archive action (or `c` on a hovered card). Archived cards can be restored; delete
  is permanent and Yab asks the user first.
- Comments with @mentions notify people; Yab asks before posting.

## Keys

`g i` inbox, `g p` planner, `g b` boards, `b` board switcher, `f` filter the board, `x` clear filters,
`n` new card below the hovered one, `z` / `Shift+z` undo and redo, `Shift+?` all shortcuts. Hover-based
keys are unreliable for an agent; prefer the open card's buttons.

## Pitfalls

- Inbox is for capture and triage; fields like custom fields only exist on board cards.
- Several workspaces are common; confirm the board before adding cards.
- Power-ups render their own UI inside iframes; if a snapshot misses one, see visual-reading.
