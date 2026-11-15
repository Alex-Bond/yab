---
name: notification-activation
description: Enable a site's browser notifications and verify its own opt-in when the user asks for notifications or monitoring.
sites: []
keywords: [enable notifications, browser notifications, push notifications, notify me, включи уведомления, уведомляй, следи за]
---

# Site notifications

A working subscription needs both permission in Yab/macOS and the site's own notification opt-in.
Yab supports site notifications and Web Push while it is running, including with the tab closed.

1. Resolve the requested site from the current tab or task context. For monitoring, identify the
   exact event the user cares about, not every notification from every site.
2. Inspect the site's settings or Enable notifications control. `eval` may read
   `Notification.permission` in a task tab; do not invoke requestPermission through eval.
3. Click the site's own notification control. A browser permission prompt belongs to the user:
   hand over when it requires their action. If macOS blocks Yab, explain the permission shown by
   Yab and let the user complete that system setting. Do not silently change a denied permission.
4. Enable only the relevant Desktop/Browser/Push setting within the site, then re-read its state.
   Do not enable email or SMS notifications unless requested. Report any unresolved step.
5. Verify the opt-in state, or a test notification if the site offers one. Do not claim delivery
   was tested just because permission reads granted.

When the user requested monitoring, use `watch` for a reply thread or the available routine tools
for a self-contained periodic check. Read their schemas for supported schedules and lifecycle.
Keep a record of checked items, stay quiet while nothing relevant changes, and report only new
matching events or a failure requiring the user. Enabling push does not itself start an agent
routine, and Yab does not expose inbox/eventFilter/grantNotificationPermission APIs.
