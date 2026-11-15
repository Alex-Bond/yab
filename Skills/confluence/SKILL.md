---
name: confluence
description: Confluence Cloud pages, spaces, search and the page editor.
sites: [atlassian.net]
keywords: [confluence, wiki, space, page, runbook]
---

# Confluence Cloud

Confluence lives under `/wiki` on the team's Atlassian site. Jira shares the same host; if the URL has
`/jira` or `/browse`, use the jira skill.

## URLs

- Page: `https://${site}.atlassian.net/wiki/spaces/${spaceKey}/pages/${pageId}/${title}`
- Page by id alone: `https://${site}.atlassian.net/wiki/pages/viewpage.action?pageId=${pageId}`
- Space home: `https://${site}.atlassian.net/wiki/spaces/${spaceKey}`
- Search: `https://${site}.atlassian.net/wiki/search?text=${query}`

The page id is the stable part; titles in URLs change when pages are renamed. Store and cite links
with the id. Check memory for the user's `${site}` and the spaces they work in.

## Finding a page

1. Open the search URL with a few distinctive words.
2. Snapshot the results, click the right one.
3. Read it with `text`: it gives the body in order, including tables, without the chrome.

For a page tree, the space sidebar lists child pages as expandable items; expand by ref.

## Editing

- Open the editor with `e` on the page (or the pencil/Edit button).
- The editor is one rich text surface. `type` replaces the text of the element it targets, so aim at
  the smallest block you mean to change (a paragraph, a table cell), never the whole body. To add, put
  the caret at the end of the last block (click it, `press` `Meta+ArrowDown`) and `press` Enter for a
  new paragraph, then type into that new block.
- Typing shortcuts work in the editor: `/` quick insert (tables, panels, code), `@` mention,
  `[]` then Space for an action item, `<>` then Space for a decision.
- Formatting: `Meta+b` / `Meta+i` / `Meta+u`, `Meta+k` link, `Meta+Alt+1` to `Meta+Alt+6` headings,
  `Meta+Shift+a` macro picker.
- Changes save as a draft as you go. **Publish** (or Update) shows them to everyone and Yab asks the
  user first. Read the page back with `text` before asking to publish.
- New page: `Meta+Alt+c`, or Create in the top bar; confirm the space and parent before writing.

## Pitfalls

- @mentions notify people as soon as the page is published.
- Restricted pages show a request-access screen: tell the user, don't request access on their behalf.
- Embedded Jira, charts and diagrams render as images or iframes; see visual-reading if you need them.
- Deleting or moving pages goes through the user's yes.
