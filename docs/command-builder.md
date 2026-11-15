# Commands with services

Planned, not built. This is the plan for commands that write to the services you use: save this page to Notion, update a Linear issue, tell Slack, proofread before sending. A command is one sentence you can read, kept from something the chat just did or written in a builder, and run by a word in the field or in chat.

Concept pages, with live prototypes of every step:

- [@ commands](https://claude.ai/artifact/9N6i4fYKY2g6TFBtXrKZ4m): @ in the field, places, chains, the first sketch of the builder.
- [The builder](https://claude.ai/artifact/Nr8Z2uaLB3qm6d1ZAQqEQt): the sheet with slot menus, And then…, Only if…, fields, Try on This Tab, the states and the `.yab-command` file.
- [In depth](https://claude.ai/artifact/M7U9PEAM8FV27zup5DP5HX): the chat offering to keep what it did, how a run becomes a sentence, the sheet part by part, a run step by step, Settings › Commands.

## What exists today

- Quick Actions ([quick-actions.md](quick-actions.md)) open an address that makes something; they never write.
- Selection commands have a prompt with `{selection} {around} {page} {url} {title} {language} {memory}`, an executor (Mac, agent, Claude, Codex, local) and a Result (In place, Beside, Below the page, In a reply field, Copy). Their editor is the 720×560 sheet in `CommandSettings.swift`.
- The ⌘J answer already has Keep as a Command and Edit Command (`FieldAnswer.swift`).
- Site skills have `read:` and `action:` lines (Notion, Linear, Slack and others, through your cookies).
- Store plugins expose tools; ones that act are marked `acts`.
- Routines ([routines.md](routines.md)) run a prompt on a schedule or a trigger.
- Missing: any @ mention, writes to a service, MCP servers of your own (agents get only yab-browser under `--strict-mcp-config`).

## A command is a sentence

> When **I type rl**, take **this page**, **write a 2-line summary and tags** and send it to **@notion Reading list**; **at once**.

Each colored word is a slot with its own menu:

| Slot | Choices | Comes from today |
| --- | --- | --- |
| When | a word, a key, a site, a mail like this, a time | Shows for, Sites, Shortcut; Routines |
| take | this page, the selection, the tab's fields, a mail, the clipboard | prompt variables |
| do | a prompt in your words, or nothing | Prompt, Model |
| send to | @service place, or a Result (below the page, in place, copy) | Result |
| ask | at once, ask first, ask when it posts | new |

And then… adds a step (then tell @slack #design). Only if… adds a condition (only if it mentions a date). Posting to people always asks, whatever the sentence says.

Services come in through skills with two new lines: `target:` names the places a service has (Notion databases, Linear teams, Slack channels), and `write:` says how to add to one. A place is kept by name, so a shared command asks the next person to pick theirs.

## Three ways in

1. **The chat offers it.** After the chat does a task that wrote to a service, or after you ask the same thing a third time in two weeks, a card under the answer reads "Make this a command?" with the sentence built from what it actually did: Keep as rl ⌘S, Edit…, Not now. Next time you ask the same in chat, the suggestion line offers Run rl, which runs without the agent.
2. **Describe it.** "save articles I read to my Notion reading list" in the field or the builder; Make turns the words into the sentence, and Make again only rewrites the words that changed.
3. **Suggested.** Repeated moves (copy a title, open Notion, paste) show up in ⌘K with Keep.

### When the chat offers, and when it stays quiet

Offers after a write to a service, after the third same ask, once per kind of task. Stays quiet after a plain question, a one-off task (a trip, a refund), anything private, and for two weeks after Not now. Never a card for a command that already exists: the suggestion line offers it instead.

### From a run to a sentence

| Tool call in the run | Word in the sentence |
| --- | --- |
| the message that started it | When I type (a short word from it) |
| `text`, `snapshot` of the tab | take this page |
| `text` of a selection | take the selection |
| the model's own writing step | do: the prompt it used, cleaned up |
| a skill's `write:` | send to @service place |
| a card you answered | ask first |

## The builder

Today's command sheet grows into it, 860 wide, all on one page:

1. Where it came from: a chat, a ⌘J answer, a suggestion or New; a link back to that run.
2. Describe it: words in, sentence out.
3. The sentence: click or Tab to a word, type to filter its menu, Return to choose.
4. Fields: one row per field of the place it writes to, each with its source (page, selection, AI, today, a fixed value, empty).
5. Try on This Tab: runs everything but the writes and shows what would be sent. From the chat the first try is the chat's own run.
6. What it can do: reads what it takes, writes only where it sends.
7. Word and key: the word works in the field and in chat; clashes are named.
8. Runs: how often, the last result, the last failure with its reason.

Keys: ⇥ and ⇧⇥ move between words, ↩ opens a word's menu and chooses, ⌘↩ adds a step, ⌘T tries it, ⌘S keeps it.

## A run

A kept command runs without the agent: its steps are known, so only the AI words cost a model call.

| Time | Step |
| --- | --- |
| 0 ms | `rl` and Return; the row turns into its run |
| 40 ms | take: title, address and text from the tab already loaded |
| ~1.2 s | do: one model call with the kept prompt, on the Mac when the command allows it |
| ~1.6 s | ask, if the sentence says so; Return is the yes |
| ~1.9 s | send: the skill's `write:` with your cookies; a 401 says Sign in to Notion, a changed schema names the field |
| ~2 s | "Saved to Reading list" with Open ⌘O and Undo ⌘Z for a minute |

## Settings › Commands

Commands are listed as their sentences, each with its runs and a switch. Ones that run on their own show their last result; a failing one says why in red ("Failing: Slack signed out") until it is fixed. ⋯ has Share (a `.yab-command` file or a Store listing), History (the last 50 runs) and Earlier Versions (every Keep is a version).

## Build order

1. The chat's offer and Run instead, on top of Keep as a Command in `FieldAnswer.swift`.
2. `target:` and `write:` in skills, Notion and Linear first.
3. The sentence in the command sheet, then fields and Try on This Tab.
4. @ in the field.
5. And then…, Only if…, triggers other than a word, sharing.
