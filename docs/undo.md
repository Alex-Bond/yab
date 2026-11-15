# ⌘Z in the window

Outside anything typed into, ⌘Z takes back the last thing done by hand in the
window, newest first. One stack holds all of it (`Browser.steps`,
`Sources/Fast/WindowUndo.swift`), so ⌘Z never skips what was just done to
reopen an older closed tab.

## What it takes back

- Tabs closed: one ⌘Z for the tabs closed together. A close already brought
  back by ⌘⇧T or the History menu is passed over.
- The row's arrangement: pin and unpin, a pin's letter, a tab's name, a drag
  in the column (one step for the whole drag), Keep and Don't Keep, a new
  folder, Move to Folder, Move Out of Folder, Ungroup, a folder's name, an
  empty folder removed. These go back as a snapshot of the row
  (`RowShape`): order, pins, kept, folders, names and pairs. Tabs opened
  since stay among today's.
- Remove Folder and its tabs: the tabs come back kept, in the folder.
- The mail pin unpinned: pinned again where it stood.
- Tabs sent to another space or window, from the menu, the keys, a drop on
  the tray or a tear-off: back where they stood, the space switched back if
  needed.
- A space deleted by hand, for a minute: its tabs, routes and own sign-ins
  come back. Its row and sign-ins are erased after the minute, or at the
  next launch if the app quits first (`spaces.erasing-soon`).
- A space renamed, a bookmark deleted, a clipboard item deleted (its data
  stays on disk for that minute, and goes at quit), a snippet deleted.

A notice with Undo up answers ⌘Z first, and its Undo and ⌘Z are the same
step. The password card's Never takes ⌘Z while it says so.

## Who has it first

- Text being edited keeps its own undo: a page's field, the address field
  with words in it, the chat's box with words or its own history.
- A page that handles ⌘Z itself (a canvas editor, Get to Know) gets it first;
  a ⌘Z the page sends back is the window's (`ContentView.pageFirst`).
- Mail has its own stack (`MailDesk.undoLast`); label actions (mark read,
  hide, delete while the corner says so, rename) and deleted drafts are on it.
- Settings: a deleted snippet comes back with ⌘Z there or the corner's Undo.

Only changes made by hand are steps (`Browser.handMade`: a press, key or menu
a moment ago); an agent's changes have their own undo (`NativeControl`).
Forgetting history and Delete All Unpinned in the clipboard stay final:
they are asked first and say so.
