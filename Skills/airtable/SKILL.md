---
name: airtable
description: Airtable bases, tables, views, expanded records, shared views and forms.
sites: [airtable.com]
keywords: [airtable, base, table, grid view, record, airtable form]
---

# Airtable

## URLs

- Home: `https://airtable.com/`
- Workspace: `https://airtable.com/workspaces/${workspaceId}`
- Table in a view: `https://airtable.com/${baseId}/${tableId}/${viewId}`
- One record: `https://airtable.com/${baseId}/${tableId}/${viewId}/${recordId}`
- Interface page: `https://airtable.com/${baseId}/${pageId}`
- Form: `https://airtable.com/${baseId}/${shareId}` or a URL ending in `/form`

Ids carry a prefix that tells you what they are: `app` base, `tbl` table, `viw` view, `rec` record,
`pag` interface page, `shr` shared view or form. Names on screen are not in the URL, so take ids from
the URL the tab is on (`tabs` shows it) rather than building one from what you read.

## Finding your way

- Search memory for the user's bases first; otherwise open Home and read the base list.
- Inside a base, the switchers are faster than the sidebar: `press` `Meta+k` for bases, `Meta+j`
  for tables, `Meta+Shift+k` for views. Type the name into the box that opens and press Enter.
- A direct link that drops you on Home usually means no access to that base or the wrong kind of
  share link, not a bad id. Say so instead of retrying.

## Reading records

- The grid is virtualized: only the rows and columns on screen exist in the page, so a snapshot of a
  big table is partial. For one record, expand it. For many, filter the view down first, then read,
  then `scroll` the grid and read again.
- Expand the selected row with `Space`; the record opens in a pane with every field as a labeled
  control. `snapshot` it (or `text` for long fields) and close it with `Escape`.
- Long cell text is cut in the grid. `Shift+Space` opens the active cell in full.
- Airtable swaps panes in place, so take a fresh snapshot after opening a record, switching a view
  or changing a filter; old refs point at nothing.

## Editing

- Select a cell and press `Enter` (or `F2`) to edit it; `Escape` cancels, Enter commits.
- New row below the selection: `Shift+Enter`. New row at the end: `Meta+Shift+Enter`.
- Date cell to now: `Meta+;`.
- Linked records, selects and collaborators open pickers: type to filter, then click the option by ref.
- Filter, group and sort: `Meta+Shift+f`, `Meta+Shift+d`, `Meta+Shift+s`. These change the view for
  everyone who uses it; if the user only wants a look, tell them, or use find (`Meta+f`) instead.
- Deleting records or fields makes Yab ask the user first. Wait for the answer.

## Forms

- Prefill fields with query params: `?prefill_${Field Name}=${value}` (URL-encode spaces), and hide a
  prefilled field with `&hide_${Field Name}=true`.
- Filling a form is fine; submitting it goes through the user's yes.

## Pitfalls

- `Meta+/` lists every shortcut when you need one not here.
- Shared views (`shr`) are read-only snapshots of a view; editing needs the base itself.
- Sign-in walls and SSO go to `handoff`.
