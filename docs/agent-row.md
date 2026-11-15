# Agents in one row

On for everyone since 2026-10-24, off in Settings › Agents › Agents in
One Row. Code: `Sources/Fast/AgentRow.swift`; the row's place over the foot in
`Side.swift`; the tabs left out of the list in `AgentFolders.swift`
(`Folders.tasks(in:rowed:)`, `work`).

A routine's run, or an agent from the terminal (Claude Code, Codex through
`yab mcp`), opens tabs for itself while you work. As a folder in the list,
with a face that reads, those pull the eye every time one starts. With the
row on, they aren't drawn among your tabs: one row over the column's foot
stands for them. Concept and every case drawn: artifact
EmeB5PoFfp6Z4MNCDQtwJP (2026-10-19).

## Whose tabs

- **Behind the row**: tabs a routine's run or an attached agent opened for
  itself (`Tab.bench`), and their subagents'; and a task Yab runs that
  nobody began in Yab: `yab "…"` from a terminal or a script (`person` not
  "app"), or one an outside agent handed over through MCP's `task`
  (`providerBackground`).
- **In the list as before**: your own tasks (⌘T, ⌘J, a chat), a tab of
  yours an agent was let into (it keeps the face while it works there), a
  tab you kept or put in a folder of yours, a routine's own kept folder
  (Keep what it finds in a folder), Yab's own work out of sight (its shut
  folder).

Left out of the list, they are out of sight the way a folded space's kept
tabs are (`Folders.away`): no place, no row, no slot for a drag.

## What the row says

Nothing at all while no agent works. Otherwise, a tab row tall, with the
ground a pin has at rest:

| When | The row |
| --- | --- |
| One agent at work | its name, its face holding still |
| Several | "3 agents" |
| One tab waits on you | that tab: its icon, its title, the hand at its end |
| Several wait | "2 need you", the hand |
| You are on one of their tabs | that tab, on the open tab's plate |

Only the hand moves. An agent from the terminal counts as at work for 90
seconds after its last call (`Session.resting`), as its face does. Done, the
row goes in 0.15 s; what a routine found is in ⌘T's Now and its chat.

## Its panel

A click grows a panel up out of the row, as ⌘K's list grows out of its pill
(`AgentRowPanel`, the same glass, 36 pt lines): the agents' tabs
themselves, each with its icon and title. Prototype:
claude.ai/artifact/Xr9dU4dk5AnFY7ak1pxsoD (2026-10-20).

- **Needs You** first: the tab, what it asks under its title, the hand.
- **At Work**: each tab of an agent at work, its face and what it does.
- **Earlier**: the rest, newest first, how long ago at the end ("4m",
  "2h"). A site's several tabs are one line, "10 tabs · 4m", which opens
  the newest.

Search at its foot takes the keys as it comes up ("Search Agents' Tabs",
by title or site); ↑↓ walk, Return opens, Escape or a click elsewhere puts
it away. A right click on a line has Show Chat, Stop (not for an agent from
the terminal) and Close. A cross in a line's upper right appears on hover
and closes that line's tabs, including all the tabs in a finished site
group. It uses a sidebar tab's cross and square, inset equally from the
line's top and end with concentric corners. A tab picked comes in front;
the row is that tab while you are on it, and the list stays as it was.

A finished run behind the row leaves no unread tick on its tabs: nobody
opens them there to read it, and an unread tab is never cleaned up (ten done
Telegram checks of a voice agent stayed for good). They close after the
usual wait (Settings › Agents, 15 minutes by default).

## Not yet

- Only the column: with tabs on top, the strip draws their folders as before.
- Only the space on screen: an agent's tabs in another space are counted
  there.
- Mail's space has no row.
- One switch for all three kinds; a choice per kind (your tasks, routines,
  agents from the terminal) is drawn in the concept, not built.

## Testing

`{"do": "row-agents"}` on a test run: `on` turns it on or off, the answer
has what the row shows and says, the workers, the tabs held and the panel's
lines (`query` narrows them as its search does); `pick` opens a line by its title. `evals/agent-row/check.py`
drives it with an attached agent and a stand-in Claude.
