# Steps in the chat

What an agent does, said the same way wherever it is said: the column's head, the dock over the page, the task page, a folder's
tooltip, the menu bar and the mail row. Code: `StepWords.swift` (the
words), `StepMarks.swift` (the marks and how they move), `ChatItem.swift`
(what a step was about, from the stream), `ChatTranscript.swift` (`ChatLive`,
what the head says, and a turn's answer), `ChatComposer.swift` (`ChatPlan`), `Chat.swift` (`waited`,
`failure`). Tests: `StepWordsTests`, `StepMarksTests`, `ChatLiveTests`.

## One table of words

Every step has three forms of its verb, as Codex has them: running
("Opening"), done ("Opened") and failed ("Couldn’t open"). After the verb
comes what it was about, in gray:

- a site for `open`, `navigate` and `fetch` ("Opening github.com"), whose
  icon stands in for the step's mark;
- a tab by its title, without the site's own name ("Notifications |
  GitHub" reads "Notifications"), as it was when the step was done in it:
  the step keeps the page (`ChatItem.page`), so its row still reads "Read
  Home / X" once the tab is closed or Yab has started again;
- for a click, a hover or a drag, the element's own words: Yab reads them
  off the element before it acts (`label` in the page's act script,
  `Agents.label`), so the row reads "Clicked “Mark as read”", not a ref;
- a search's words in quotes, a file by its name, a command without the
  shell around it (`zsh -lc '…'`), cut in its middle when long;
- keys drawn as keys (`KeyGlyphs`): "Pressing ↩".

A verb with nothing after it drops the word that would hang off its end:
"Searching the web", not "Searching the web for".

Yab's own bookkeeping (memory, history, skills, the task's name, the
profile, a look at the tabs, waiting for a page) is quiet: the head says
it while it runs ("Looking in memory"), and nothing else does.

Another server's tool is said by its server: `mcp__linear__create_issue`
reads "Created an issue in Linear", with Linear's icon. A server Yab
doesn't know reads "Using Acme", with the plug.

Claude Code's tools (Read, Grep, Glob, Bash, Edit, WebSearch, Task,
TodoWrite…) and Codex's items, from the app server or from `codex exec
--json` (`ChatItem.codexExec`: commands, file changes, web searches, MCP
calls, the plan), go through the same table. A status written the old way
("click · github.com") is put in the same words (`StepWords.say`), so the
dock and the menu bar say "Clicking on github.com" too.

## A turn at work

The turns never show a step (2026-10-19, the user's call): no live line,
no "Worked for", no list of steps, on the Mac and on the iPhone. While the
agent works only the typing capsule stands under your words. What it is
doing is said in one place, the line under the chat's name in the head
(`ChatLiveWords`).

- The head says "Working for 12s", not counting the time it waited on you,
  then the step going on ("Reading Notifications") or "Thinking", or the
  first line of what it thinks.
- What the head says is held (`ChatLive`), so it never flickers. Steps
  often come a few at once and are over in a tenth of a second: reading a
  page, looking at it and naming the task took a third of a second, and a
  line that followed each one said three things in that time. Each thing
  it says stays a second at least; a step that came and went while another
  was said gets its second after; Yab's own bookkeeping is said only once
  it has run 0.4 s. A question for you is said at once. It is worked out
  from the steps' times alone, so the head, the dock and the menu bar say
  the same.
- The answer grows out of the typing capsule: one surface, its frame going
  from the capsule's 64 by 36 to the answer's first bubble on
  `Motion.reshape` (0.3 s), its corner min(18, h/2) all the way, its fill
  the capsule's, the tail at the foot's corner (`ChatGrowth`, `ChatWords.grow`).
  The dots and the capsule's round marks go in the first 0.1 s; the words
  come in over the last two thirds. The bubble is laid out at once at the
  size its first message will be once written out, and only its drawing
  moves, so nothing is laid out again for each frame. With Reduce Motion
  the capsule is the answer at once.
- The answer is written out. With its thinking hidden, Claude hands over
  the whole answer in one lump the moment it ends (all of it within ten
  milliseconds, the turn over twenty after), so it stood there at once.
  A lump of more than 40 characters is written out a few words at a
  time, twelve times a second, in a second or so (`WriteOut`), the
  newest words soaking in as streamed words do (`FreshText`). Words
  that do stream show as they come, the bubble growing line by line. An
  answer opened later stands at once; the ⌘J field writes out its answers
  the same way.
- Nothing stands under an answer, as in Messages: Copy, Ask Again, Repeat
  and Show Tabs are in its right-click menu (`ChatAnswerMenu`), and Show
  Tabs opens the tabs it worked in, never its steps. A turn you stopped
  says so in a quiet line: "You stopped after 58s".

## Waiting on you

A step that asks (`ask`, `AskUserQuestion`, `handoff`, `computer_access`,
`folder_access`)
or a press held for your yes (a permit in one of the chat's tabs) is a
wait, not work. The head says "Waiting for you · 3s" and the work's clock
holds; the face raises its hand. What it asks stands in the turns as its
message.

A pick (`ask` with options) is asked as in a conversation: the question is
the agent's message in the turns (`ChatItem.question`, written by
`Agents.handoff`), its choices alone stand over the field in `ChatAsk`, each
by its number, and the field says "Or answer in your own words…". The one
picked, or the words typed, follow the question as your message (`.chose`),
the card goes, and the typing bubble comes back at once. No "Waiting for
you" anywhere in the turns.

The choices grow up out of the field's top (`ChatAsk.grow`, 0.3 s on
`Motion.reshape`): rows at least 32 high, 2 apart, the number on an 18 pt
badge. With the field empty, 1–9 pick, ↑↓ light a row and ↩ picks it, and
Esc puts the choices back into the field, the question still standing (↑
brings them back; words typed still answer it). A pick lights at once, its
badge in the ink with no motion (`ChatChoosing`), and 40 ms later it is
answered: the choices shrink back into the field in 0.22 s as your words
come up.

Anything else it asks (Send?, Upload?, Sign In, Use this tab?) is a card in
the field's place (`AgentPlaque` with `fitted`), grown out of the field and
shrunk back into it once answered. The question leads on its own line (the
hand, 13.5 medium, up to three lines, never cut for the buttons), then whom
it goes to, every address, then the words a yes would send (three lines, ▴
opens 14), and the answers 28 high at the foot on the right. Its keys are
the page's (Esc Not Now, ↩ or ⌘↩ for a weighty yes, ⌥ for Never Here),
taken from anywhere in the window nothing is typed into while the field is
hidden. After a yes that sends (`AgentPermit.sends`, not a payment) the card
stays (`Tab.sending`): the yes rewords to "Sending" around the letters they
share (MorphWords), the button widening round it, and Not Now is off. Once
the call it was for has taken the yes (a mail or a message says how it
went), the card shrinks into the field after half a second at least; the
agent's answer says it went, no success card. If it didn't go, one red line
says why where the words were, and **Try Again** takes the yes's place and
keys; Not Now (Esc) puts it away.

## When it fails

The head says "Couldn’t finish after 12s". In the turn a box says what
went wrong in plain words (`Chat.failure`: the agent's server failed
partway, it is out of room on the plan, the connection dropped, it stopped
before it finished), the raw error small under that, and **Try Again**,
which sends the same words again, with the tabs and files that went with
them (`Session.sent`).

When the error names a file that went with the words, or is about a
picture and one picture went, or a file has gone since, the box says which
one in one line ("“shot.png” was moved or deleted.") and offers **Ask
Without It**: the same words again without that file
(`ChatAttachment.blamed`). Before sending, the field does the same: a file
moved, deleted, shut or over 20 MB since it was taken is said in one line
over the field, its chip's name in red, Send waits, and Ask Without It
sends the words without it (`ChatAttachment.trouble`). An asleep tab that
goes with the words loads as they are sent, and the agents' `text` tool
loads an asleep or emptied tab before reading it, as `snapshot` does: it
used to read an empty page. Eval: `evals/chat-attach-trouble/check.py`.

## Two lines down the turn

Inside the column's 12 pt margins (W wide; `ChatLook.turnsInset`), a turn
keeps two lines on the agent's side and one on yours (2026-10-05; the
margins and the tail as Messages on iOS 26 since 2026-10-12, measured on
an iPhone: bubbles near the edge, the field deeper):

- **0, the bubbles' body.** The tail hangs under a bubble's foot corner,
  5 under it and inside its width (`MessageBubble.tailDrop`), so it takes
  no room beside the bubble. Cards and plates of the agent's stand here and
  end at W: a table as cards or as a grid, code, the mail draft, the
  notebook card, a boost's pictures. The chips over your words end at W.
- **12, the words** (`MessageBubble.words`, the bubble's 12). Words inside
  any box stand 12 in, so on this line: a bubble's, a card's, a grid's
  cells, code. The turn's own lines stand on it too: the line on who
  carried on, a stopped turn's, a failure, the offer to save steps as a tool.

The field and what stands over it (a pick's choices, a page's ideas, the
queued words) stand deeper, 20 in (`ChatLook.fieldInset`), as Messages'
field stands in from its bubbles.

Down the turn: the agent's messages in a run 4 apart, a card 8 from what
is round it, what follows the answer 8 under it whatever its last block,
turns 24 apart. Before this, the buttons' glyph stood at 0 (a −6 from
when the answer was bare words at 0), "Worked for" at 6, tables at 0 with
their words at 10 or 12, chips at W.

## The column's head

As a messages app heads a conversation (`ChatHead` in `ChatColumn.swift`):
the agent's face in the middle, the same face its tabs wear (`Face`), on a
glass circle, and under it, on glass, the chat's name and one line.

- A new chat: the model picker, the only place the model is chosen.
- At work: what it is doing ("Reading Notifications", "Thinking"),
  words alone: no site marks, no count of tabs (`ChatLiveWords`).
- Otherwise, waiting on you included: the model that answers, with no
  picker. What it asks stands in the turns and the face raises
  its hand, so the head doesn't say it again.

The face follows the chat's tabs: the newest step's pose for 2.2 seconds,
thinking between, the hand while it waits on you, looking down when it
failed, glancing about otherwise. No tick: done, it is only itself again.

On the left, the chats' clock, and on the chat's own screen a glass arrow
back to its turns. On the right, one glass ⋯ (`ChatMoreMenu`), drawn as
⌘K's actions and the + menu are, its search at its top where it opens
down from its button: this chat's things (Copy Answer, the corner saying
Copied, Pin Chat, Rename Chat…, Archive…, Stop while it works, else Delete
Chat…), then the chats' (Change Model… in a new chat, New Chat, Your Chats,
Hide Chat with its keys).

A click on the face or the name opens the chat's own screen (`ChatInfo`),
grown out of the head: the face, laid out at the screen's size and only
scaled down in the head, grows into its middle and comes down under the
buttons; the name's glass fades; the turns go at once and the screen rises
in after them, so the two are never read through each other. On it: the
name, the model and when it started, round glass buttons of the hero size
(48, `ButtonSize.hero`: Pin, Copy Answer, which says Copied with a tick
for a moment, its width kept, Archive or Stop), and the pages it read: its
own tabs and its subagents', the tabs of yours it looked at, and those you
gave it with your words, a click going to one still open. The glass arrow
on the head's left goes back the same way.

Pinned is what used to be "kept for good": a pinned chat never expires
and heads the list under Pinned. Archive and Delete ask first, and Rename asks
for the name, all in the app's own card over the page, as every other
question is (`ChatQuestions`, `Question`): "this chat", not its name, which
is often a question of its own. Once archived from the head, the column
goes to the chats, where it no longer is; Unarchive doesn't ask. A name
you give is its own: the model on this Mac never names it again.

What it costs, measured (2026-09-30, `bench idle` around five toggles):
the turns and the field stay under the screen, hidden, so going back
builds neither again; they are hidden with no fade, since a fade of the
whole turns redrew all of them for every frame; the motion is on
`Motion.chatIn`, not a spring with a long tail; and the screen makes a
scroll view only for more tabs than fit. Together that took opening from
about 2.5 times the cost of opening the list of chats to about 1.5, and
going back below it. The ⋯ menu costs what the + menu does.

As the turns scroll up under the head, the face shrinks to 28 points and
the name and the buttons come up with it, as a messages app's head does:
only scaled and moved, never laid out again (shrinking by layout cost
about 50 ms of main thread each time the column came out on a long chat).
What tells it is a 1 point mark at the top of the turns going out of view,
not every point scrolled; a chat that opens at its foot starts small with
no motion. Nothing darkens or fades the turns behind the head: its glass
carries 70% of the column's ground (`ChatHead.tint`), so the name reads
over whatever passes under it.

A name that is only the first thing asked, cut, is said again in two or
three words (at most 24 characters) by the model on this Mac, once, the
first time the chat is in the head (`ChatTitles` in `ShortNames.swift`), so
it fits the glass. A name the agent gave with `name`, or a routine's, stays.

## The plan

A plan the agent keeps (Claude Code's TodoWrite, Codex's todo list) sits
over the field while the chat works: a ring filled as far as it got, "Step
2 of 3" and the step's words. Its tip lists every step. A plan of one step
shows nothing.

## The marks

Thirty-four drawings, one for each kind of work: the lens for a search,
the open book for a file read, the pencil on its pad for an edit, the
prompt for a command, the cord and plug for another server's tool, the
hand for a request to you, a tick, a cross. They are drawn on Central's
shapes, on the 24-point grid in the 2 pt weight of every icon in Yab
(`Glyphs`).

While a step runs, its mark makes one gesture of that work on a beat: 0.6
s into every 4 s, counted from when the step began (in the head, from
when the line took it up). It is the beat the light passes through the
verb on, so the light and the mark move together. A done step's mark
stands still. A tick is written once as it lands, a
failure shakes once, a request to you waves once and waits; drawn again
later, they rest. With Reduce Motion, no mark moves.

They move as Codex's Lottie icons do: every frame is geometry. A turn or a
move is baked into the path, and what grows or shrinks moves its points,
so the stroke never thins under a scale. The marks Codex has too (Search,
Tasks, New chat, More, Library, Plugins, Projects, Memory, Thinking) keep
its keyframes and curves frame for frame at 60 fps; the rest keep its
clock and curves (`StepCurve`). Each kind is sampled once into keyframes
(`StepArt.frames60`) that Core Animation plays on the render server, in a
group repeating every 4 s, so a running step costs the main thread
nothing. Every frame of a mark's path has the same points and curves
(`StepMarksTests`), which is what lets Core Animation ease between them.

A mark sits in the middle of its 14-point box, on the middle of the
words beside it, its box at the column's left edge with every other
mark's and icon's. Core Animation hangs a sublayer transform from the
layer's middle, not its corner: placed as if from the corner, every mark
sat 2.5 points right of and under where it should, off its words
(`StepMarksTests`).

A site's icon stands in for the mark of a step that went to a site. On a
dark page a dark icon (measured once, `SiteMark.dark`) sits on a light
tile, so it doesn't disappear.

## The light

The light is a band of the ink passing through the words, seen only
through their letters: the band is a Core Animation gradient moving on
the render server (`Glint`), masked by the words themselves (`glint()`),
so the main thread does nothing for it. "Thinking" rests in the muted
gray and lights up to the ink; a step's verb rests a step under the ink
(`Glint.lit`, as a done step's), so the light has somewhere to take it.
It used to be a band of the ground laid over the words, a rectangle that
darkened them and showed wherever the column's glass wasn't the ground.

## What it costs

Measured with `bench idle` for 10 s in each state, in a test world where a
stand-in Claude holds each step, on the build before the marks (A) and
after (B):

| State | Main thread, A → B | Whole app, A → B | Main wakes a second, A → B |
|---|---|---|---|
| A search running | 1.24% → 1.33% | 1.48% → 1.60% | 26.0 → 25.9 |
| An edit running | 1.20% → 1.19% | 1.49% → 1.55% | 26.7 → 27.1 |
| Waiting on you | 1.26% → 1.30% | 1.98% → 1.50% | 31.0 → 33.7 |
| Done | 0.31% → 0.37% | 1.30% → 0.78% | 8.8 → 8.9 |

The same, within noise. The wakes while a chat works were there before:
the column looks at its session ten times a second (`ChatFeed`), and the
head's clock ticks every second; three a second are the test's own, which
keeps the window off the screen. For that reason the render server's share
wasn't measured.

## Testing

- `swift test --filter StepWords` and `--filter StepMarks`: every tool
  has its verbs and a mark, bookkeeping is quiet, questions wait, what a
  step was about comes from its input, another server's tool is named by
  its server, failures say why, waiting isn't work, the plan is read,
  Codex's exec items show; the curves, keys and Central's path data, every
  mark keeping its shape from frame to frame, each gesture ending where it
  started, every mark in the middle of its box.
- `swift test --filter ChatLive`: steps over in a tenth of a second each
  get their second on the line, a newer step waits for the one said to
  stand its second, bookkeeping is said only once it has run a while,
  many quick steps skip to the newest rather than fall behind; a lump is
  written out in about a second, a word at a time.
- End to end, in a test world: a stand-in for Claude Code
  (`YAB_AGENT_CLAUDE`) that speaks stream-json and makes its steps for
  real through Yab's MCP (open, snapshot, click, type, press, screenshot,
  ask, handoff), each step waiting on a gate so its state holds for a
  picture. `bench agent-run`, `agent-chat show`, `agent-answer` and
  `agent-handback` (with `skip`) stand in for the person. Give every tool
  call an id of its own across turns, as Claude Code does: a stand-in
  counting from 1 in each turn writes its second turn's steps over the
  first's.
