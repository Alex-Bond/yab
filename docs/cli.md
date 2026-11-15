# Use Yab from a terminal or an agent

Yab is a browser on this Mac. Use its signed-in websites without taking over the user's window.
Ask Yab's agent to do a whole task, or use MCP tools or `exec` to drive tabs yourself.
Tasks use the AI plan selected in Yab; MCP and exec do not start another model.

## Install

With Yab in /Applications, run this once, then open a new terminal:

```bash
/Applications/yab.app/Contents/MacOS/yab setup
```

This adds the command to PATH and installs the browser skill and MCP connection for Claude Code
and Codex when their CLIs are installed. Use `yab setup command` for just the command. For other clients, see
`yab guide setup`. Connect an AI plan in Yab before delegating tasks.

## Common tasks

1. Ask Yab to do a browser task:

```bash
yab "Find the unread message from Alex in Slack and summarize it" --access browser
```

It prints `session <id>`, progress, then its answer. Ctrl-C stops it. Use `--access browser`
for website work. Request `--access full` only when the task needs this Mac's files or terminal;
name files by their full paths. Mac access may require approval in Yab.

2. Choose the task's AI plan:

```bash
yab "Check Stripe for failed charges this week" --cli codex --effort high --access browser
```

3. Check running and recent tasks:

```bash
yab session list --json
```

4. Continue, redirect or stop a task. Replace SESSION_ID with an id from the list:

```bash
yab session resume SESSION_ID "Only include this week"
yab session steer SESSION_ID "Check the other workspace instead"
yab session queue SESSION_ID "Then summarize the results"
yab session stop SESSION_ID
```

Resume without text follows a running task or continues one that is waiting.
Steer changes its current work; queue adds work after it finishes the current request.

5. Run browser steps yourself, without another AI task:

```bash
yab exec 'const t = open("https://example.com"); return t.snapshot()' --json
yab exec -f steps.js --json
```

Create steps.js first if using the file example. `exec -` reads JavaScript from stdin.
Each exec has fresh variables and `keep`; to continue with a tab, use its returned id with
`tab(id)` in your next script. See `yab exec --help` for time and output limits.

6. Use MCP from your own assistant:

Configure a local stdio server with command `/Applications/yab.app/Contents/MacOS/yab` and args `["mcp"]`.
Then call `open`, `snapshot`, `click` and `type` through that client's Yab tools.
`yab mcp` is a protocol server, not an interactive prompt. `yab guide mcp`
explains the tools. The MCP `task` tool delegates to Yab's agent, just like a CLI task.

7. Look up a site's instructions or relevant memory:

```bash
yab skills list
yab skills show gmail
yab memory search "project name"
```

Read a site's skill before acting there. Search memory only when relevant to the user's request;
don't edit its files directly. `yab memory list` lists pages; `memory show USER.md` reads one.

8. Schedule a task:

```bash
yab every "weekdays 9:00" "Check my mail for anything that needs an answer today"
yab every list
```

Routines use this Mac's local time and run while Yab is open. If Yab was closed, a missed run
happens once when it next opens. With an id from the list, use `every pause ID`, `every resume ID`,
`every run ID` or `every remove ID`. Other schedules include `daily 9:00,18:00`, `monthly 1 9:00`,
`first monday 9:00`, `every 2 weeks mon 9:00` and `yearly oct 6 9:00`.

9. Keep Yab available in the background:

```bash
yab status
yab serve
```

Tasks wake a closed Yab without bringing a window forward. It normally quits after 30 idle
minutes; serve keeps it running. `serve --no-person` refuses requests that need someone at Yab.
`serve --stop` stops Yab, including active tasks. Use it only when that is intended.

## When Yab needs the user

Exit 3 means the task needs input. For a question, ask the user in your chat, then run
`yab session resume SESSION_ID "their answer"`. Sign-ins, captchas, codes and approvals
may need the user in Yab. Tell them what is waiting. A caller normally gets control back after
15 seconds (unless YAB_WAIT_PERSON overrides it); `--wait-person MIN` changes that wait,
not the pending request's lifetime.
`--no-person` refuses requests that need a person instead of waiting.

Task exit codes: 0 done, 1 failed, 2 invalid usage, 3 needs the user, 130 stopped.
Exec also uses 124 for a timeout. After an interrupted action, inspect the state before retrying.

## Tab ownership and permissions

- Open agent tabs by default, even if the same site is already open. Use a user's tab only
  when they explicitly name it as the target. Never close their tab with the page `close` tool.
- Read a snapshot before acting. Use refs from that snapshot; actions already wait for changes.
- Only send, post, pay or delete when the user asked. Respect refusals; don't try another route.
- Use `sign_in` for a saved password. Hand captchas and sign-ins you cannot complete to the user
  with `handoff`. Never solve a captcha. Stop on unusual-traffic or rate-limit warnings.
- `open` and `fetch` choose a signed-in space when possible. Check `spaces(site)` before saying
  the user is signed out; choose a space explicitly when they need a different account.
- Use Yab's tools, not desktop keystrokes, Computer Use or AppleScript, to control its tabs.
- If agents are disabled, ask the user to enable them in Settings › Developers.

## More commands

`yab --help` lists commands and task options. `yab guide mcp` describes page tools;
`yab guide setup` covers installation and removal. Tool schemas are the parameter reference.
Use `native_context` and `native_actions` to inspect Yab settings and tabs before `native_apply`.
`more_tools("help")` gives product help; `more_tools` also discovers mail, files and other tools.

Files and mail commands use ids from their search results or tool output:

```bash
yab files search "signed lease"
yab files read FILE_ID --path
yab mail read THREAD_ID
yab mail file THREAD_ID 1 --path
```

Replace FILE_ID and THREAD_ID before running. Files read returns the local path and, unless
`--path` is given, extracted text. Mail file retrieves the numbered attachment.
`yab https://example.com` opens a page in the user's window; use MCP open for agent work.
`yab import` lists other browsers; the user can run `import chrome` to bring sign-ins over
after approving in Yab and macOS. An agent must not perform that import on their behalf.

For setup and server details, see [headless.md](headless.md). For the implementation, see [agents.md](agents.md).
