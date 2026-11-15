---
name: yab
description: Inspect or change Yab settings, spaces, tabs, chats and routines using its native tools.
sites: []
keywords: [yab settings, browser settings, manage tabs, настройки yab, настройки браузера, организуй вкладки, управление чатами]
---

# Change Yab settings and organize tabs

For a product question, use Yab's guide and product reference. For a change:

1. Read `native_context` for current settings, spaces and tabs.
2. Read `native_actions` for supported actions and their argument schemas.
3. Call `native_apply` with a listed action and the current snapshot token.

For example, to turn off Energy Saver, find `settings.set.energy-saver` in the catalog and use its
schema to choose `off`. To group tabs, inspect their ids and use the listed `tabs.group` action.
To undo a change, use `native_undo` with the returned undo.changeId, when undo is available.
Read the tool schemas; never invent action IDs or settings.
Respect the user's current permission mode and check the returned operation/state before claiming
success. For asynchronous work, inspect `native_operation` until its outcome is known.

Use the task/session tools actually offered for chats and the routine tools for schedules. Read
existing definitions before updating and preserve unrelated fields. Archive, delete, connect or
change access only within the user's request. Do not expose secrets or unrelated transcripts.

To create reusable instructions, read `skill-creator`. To change a website's appearance, read
`boosts`. For site notifications, read `notification-activation`. Do not use desktop keystrokes or
AppleScript to drive Yab windows; its native and page tools preserve tab ownership and permissions.
