# A tab's card

Rest the pointer on a tab and its card comes (`TabGlance`, `Glance.swift`).
Besides the tab's name, the card says who or where the thing is, the one
thing about it now, and the one thing to do about it that a click on the tab
would not. What it says is `TabGist` (`TabGist.swift`), worked out from
what the tab already knows about itself and from what a live folder last
read about the thing it shows. Nothing is read from a site for the card
alone. The concept, every state drawn, is the artifact at
https://claude.ai/artifact/TV3PhNaBKj1xj1mArtW7Lc.

## The form

- **Title.** A pull request's without its tail ("by mira · Pull Request #412
  · acme/yab · GitHub" goes, `LiveGitHub.shortTitle`).
- **Facts.** "mira · #412" with mira's initial for a pull request,
  "YAB-212 · YAB · due Oct 13" for a Linear issue, "mira · YAB-231 · YAB"
  with mira's initial for one where mira named you, else the site as before.
- **Now, one line.** Never wraps: the words are written short and a long
  one ends in an ellipsis. Ink when it is something for you, muted when it
  only goes on. Nothing to say, no line.
- **One button**, at the line's end. It only goes where a click on the tab
  does not (a pull request's Checks or Files) or does the obvious thing here
  (Pause, Play, Sleep, Reload). It never acts on the site.
- **The page's picture** only when there is nothing else to say.

## Which line

The first that applies:

1. **Not sent**: something typed on the page (`Tab.draft`).
2. **On a call**: camera or mic in use.
3. **Not responding**, for how long (`Tab.deaf`), with Reload.
4. **A chat at work**: "Answering · 1m", "Researching · 12m", "Building ·
   40s", muted, no button; then "Answer ready 2m ago" (a builder's "Done
   1m ago") in ink until you open the tab. See below.
5. **What waits for you** on the site, a live folder's word that needs you:
   Failing (Checks), Review and Changes (Files), Late by N days, Mention,
   Comment, Request. A Linear mention or comment says the comment's first
   words: Mention “which one ships?”, no button.
6. **Playing or paused**, with the time left (`Tab.tune`), with Pause or Play.
7. **The other words**: Ready to merge, Shared with you, Changed since you
   looked, New.
8. **Uses 2.3 GB**, over a gigabyte, with Sleep.

## Where the words come from

Every live folder's reading is kept by the key of each thing it lists
(`LiveSeen`, noted in `LiveFolders.apply`). A tab finds its thing by its own
live mark or by its address (`LiveText.thing`): a GitHub pull request or
issue, a Linear issue, a Notion page, a Google file, a Figma file, a YouTube
video. So a pull request opened by hand, anywhere, says what the folder last
read of it. Without a folder of that source, the card says only what the tab
knows.

Linear's due date is kept on the item (`LiveItem.due`) for "due Oct 13" and
"Late by 2 days".

## What GitHub does not give lightly

Dia's card also has +/− lines, the files count, merge conflicts and the
checks by name. On 2026-10-15 none of these came from a request as light as
the inbox's: the pull request's page JSON (`Accept: application/json`) is a
shell of channel ids, `/checks` loads its list after the fact, `/files` and
`/changes` are hundreds of kilobytes of HTML. So the card leaves them out
rather than read a heavy page on every hover.

## A chat at work

Claude, ChatGPT, Perplexity, v0, Lovable and Bolt answer for minutes while
you are in another tab (`ChatBusy.swift`). A small script on those sites
alone (`chat-busy.js`) watches the site's own Stop control: there, the page
is at work, since when and its word (Answering; Researching for ChatGPT's
deep research; Building for the builders); gone, it is done. One selector
list per site in `ChatBusy.sites`, each with a saved page in
`evals/chat-busy/fixtures`. A site whose control isn't found says nothing:
the tab is as it was.

A tab out of sight is a hidden page to WebKit, with no animation frames and
timers slowed. The script uses neither to hear the end: a MutationObserver
is called as the answer's words land, and the control going is a change
like those. `evals/chat-busy/run.py` checks an answer streamed for 40 s
behind another tab reaches Yab while the page is hidden. A tab at work is
not put to sleep ("answering").

The mark says it at its bottom corner, the call's dot's place and cut
(`ChatCorner`): the loading ring, 6 pt, while it works; a filled blue dot
once it is done and you haven't come back (blue, as unread is in Mail:
red is the microphone). Read as a finished task's tick is (`AgentFeed`,
docs/agent-tasks.md): once the tab is in front of you, a beat later. Done
while it is in front of you, nothing. A call's dot wins over both. No words
on the row.

## Corners

The card is a popover beside its tab: `Radius.floating` (14). Its button,
`.yab(.small)` at a control's 8, sits `BarFrame.inset` (6) in from the right
and the foot, so its corner runs on the card's, as the find bar's buttons
do; the words are 12 in. A folder's or a pin's preview keeps its list's
corner, `DropFrame.corner` (12), rows 4 in. A card that asks over a page (a
microphone, a password) is `.cardFrame()`, 20.

## The pointer

A card with a button takes the pointer and holds while the pointer goes from
the tab to it (the folder preview's corridor, 0.35 s): `TabGlance.holds`,
`taking`. Without a button it never takes the pointer, as before.

## Testing

`TabGistTests` holds the rules. On a `--test` run, `bench glance` with
`"words": "failing"` notes what a folder would say of the tab's thing and
answers the card's title, facts, line, button and whether it holds.
