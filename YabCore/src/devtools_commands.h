#pragma once
#include <cstring>

namespace yc {
// Resolve by name against the loaded CEF, never copied numeric IDs. Unknown
// IDs (-1) must not accidentally consume an unrelated command.
inline const char* DevToolsCommand(int command, int (*resolve)(const char*)) {
  const char* names[] = {"IDC_DEV_TOOLS", "IDC_DEV_TOOLS_TOGGLE",
                         "IDC_DEV_TOOLS_CONSOLE", "IDC_DEV_TOOLS_INSPECT"};
  const char* actions[] = {"toggle", "toggle", "console", "inspect"};
  for (unsigned i = 0; i < 4; ++i) {
    int id = resolve(names[i]);
    if (id >= 0 && command == id) return actions[i];
  }
  return nullptr;
}
}
