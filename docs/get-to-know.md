# Getting to know you

Get to Know is one optional context read by the AI the person connected in
Yab. It reads browsing history and signed-in pages, sends page text to that
AI under the person's account, and keeps notes, a form profile, addresses,
and a report. The Allow disclosure names that scope, the connected AI,
roughly ten minutes, the absence of site posts or sends, and AI › Memory
for inspection and clearing.

Provider connection, a CLI login found elsewhere, and context permission
are separate. Installed or signed-in CLI metadata is only an offer to
Connect. Explicit Yab Connect or API-key acceptance grants that provider;
a persisted Disconnect wins over later CLI login and legacy migration.
Only completed manual task/chat history can migrate a provider's old use.
Automatic Get to Know, routine, system, remote and external-MCP records do
not establish provider permission.

## Starting a read

The welcome's context card has **Allow** and **Not Now**. Other Get to Know
entries use the same disclosure and Allow action: Settings › AI › Memory,
the new-tab row, the notebook, and the form's profile offer. A valid run
already under way is reused. Otherwise Allow creates a run-specific,
world-specific permission before `Agents.setUpMemory` can launch anything.

Connect, How to Ask's Continue, Not Now, and general Daily Suggestions do
not start Get to Know or grant its permission. Bare `setUpMemory()` and
CLI/direct prompt-prefix attempts without Allow are refused, including
quiet, delegated and resumed variants. The literal prompt is not a grant.

Morning checks are a separate recurring choice. Only the visible **Keep
an eye on things for me** action, whose detail says mornings and after a
break, grants it. The general agents switch, old watch boolean, migration,
and a one-time context Allow do not. Mail replies written ahead use the
existing Mail permissions, `mail.ahead` and `mail.agents`; they neither
require nor inherit morning permission.

Deliberate `yab setup claude` and Developers tool registration can install
external MCP through a separate, single-use local setup permission. Its
exact allowlisted MCP registration arguments cannot start AI, read an
account, send a message, or grant Yab provider/context permission.

## What the agent can do

Get to Know runs browser-only, without subagents, in a shut folder. Its
notebook is held there by Yab and is never the agent's page to control.
Owned tabs stay out of front; the folder opens its chat, and its menu can
stop the run. The usual ten-minute wrap-up and fourteen-minute deadline
remain. Completion opens the notebook in the folder's place; failure or
stop leaves a truthful terminal status.

The common Bench preflight runs before remote readers, tab resolution,
DOM work, cookies or history. A context run admits only enumerated reads
and context-store writes. Navigation is http/https GET only; internal,
file, data and script URLs, arbitrary page scripts, clicking, typing,
sign-in, account operations, posts and sends are refused. The browser's
navigation boundary also rejects privileged redirects. Missing or revoked
provider, purpose, turn or context authority stops managed tool calls.
Explicitly attached external MCP retains its separate permission model.

Profile from memory is a narrower derivation: it can read existing notes
and update derived profile/address fields, and cannot read sites or
history. Episodic extraction and the daily memory pass are memory-only.
They do not acquire the context collection permission.

Every asynchronous read/write captures an immutable admission, including
provider and purpose generations, turn and context epoch. A revoked old
queue cannot borrow a later Connect, morning opt-in or newly admitted
manual chat turn. Helper processes validate provider permission at the
actual process-start boundary. Credential/status discovery does not grant
permission, including in test worlds.

## Inspecting and clearing what is kept

Existing AI › Memory, its Markdown editor, and Notes About You remain the
inspection surfaces. The notebook shows notes, photos, report, form-profile
fields and Wallet addresses. They remain reachable when only structured
data is left and when a provider is disconnected.

`ContextPrivacy` serializes collection, field provenance and clearing for
one Store/world. Learned structured writes prepare protected before-images
before changing data. A clear revokes the context generation first, removes
notes/photos/report, rolls back still-owned fields to their exact previous
values, and deletes an unadopted context-created address only when safe.
Trusted later manual edits, including blank, same-value and ABA edits,
remain. Card/password secrets and unrelated approved routines are outside
this clear. Billing references are checked through card attributes only.

Historical fields without trusted provenance are **unresolved**. Their
source text and old edited flags cannot authorize omission or deletion.
Each needs explicit Keep, Remove, or Restore when an earlier value is
actually evidenced. Unexpected post-image changes become review items;
stale reviews, failed writes, failed note deletion, and failed journal
retirement cannot report success. Before-images remain recoverable until
the operation completes.

Sync uses the existing journal's full hybrid-clock stamps and CRDT
removals. A later wall time alone cannot establish that an unknown remote
value was created after clearing. Unknown versions remain unresolved;
accept/reject binds exactly the reviewed version. Old sync deliveries,
photo completions, report synthesis, editor debounce, Undo and other late
writers cannot recreate cleared context under a newer generation.

The Memory review card's full summary, historical decisions and pending
Sync-version replay must be verified together before claiming end-to-end
clear acceptance. The backend's isolated tests are not native UI proof.

## Verification

The exact-main regression is frozen from main
`aae5c077e56b91f98ececa1f311e6fcd3c5ea001`: a real passive reader observes a
synthetic signed-in Claude CLI, no Connect occurred, and `canRunTasks()`
incorrectly returns true. Candidate readiness tests retain their actual
status/key fixtures and original assertions, adding explicit isolated
consent where intended.

Native consent acceptance uses only a reviewed production-identity app,
Golden's exact launcher, a validated task-owned HOME, an immutable
hash-pinned token-free Claude identity seed, and a harmless fake Claude.
Only Claude is supported by this fixture contract. Invalid fixture inputs
fail closed before shell fallback or host setup/account readers. The
separate testing/env-gated control socket invokes fixed semantic UI
handlers and observes state/app-drawn media; it never sets consent directly.
It must be reported as semantic handler proof, not a physical pointer test.

A fresh native run starts welcomed=false and bench=false. The no-Connect
case must show zero AI dispatch; after Connect, skipping context must show
zero collection; only the actual Allow action starts it. Separate receipts
cover the explicitly explained recurring action and Mail Ahead's own
permission. Ordinary Golden's `YAB_AGENTS=none` and producer-disabled
profile cannot prove these cases.

Exact main has no equivalent agents-off control socket, so a native
before can be only an immutable launch receipt unless another approved
observation exists. Do not patch its bundle, enable bench for the before,
broadcast CLI setup, use a live profile/credential store, or present a
fixture's pretended state as consent. Relaunch and generated HOME artifacts
remain subject to the reviewed launcher contract and actual focus/test
screen prerequisites.
