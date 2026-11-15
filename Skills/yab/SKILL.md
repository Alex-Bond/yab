---
name: yab
description: Inspect or change Yab settings, spaces, tabs, chats and routines using its native tools.
sites: []
keywords: [yab settings, browser settings, manage tabs, настройки yab, настройки браузера, организуй вкладки, управление чатами]
---

# Yab itself

For a product question, answer from Yab's guide and product reference. To perform a change, use
`native_context` and `native_actions` to inspect the actual targets, then `native_apply` with a listed
action and the current snapshot token. Read the tool schemas; never invent action IDs or settings.
Respect the user's current permission mode and check the returned operation/state before claiming
success. For asynchronous work, inspect `native_operation` until its outcome is known.

Use the task/session tools actually offered for chats and the routine tools for schedules. Read
existing definitions before updating and preserve unrelated fields. Archive, delete, connect or
change access only within the user's request. Do not expose secrets or unrelated transcripts.

To create reusable instructions, read `skill-creator`. To change a website's appearance, read
`boosts`. For site notifications, read `notification-activation`. Do not use desktop keystrokes or
AppleScript to drive Yab windows; its native and page tools preserve tab ownership and permissions.
