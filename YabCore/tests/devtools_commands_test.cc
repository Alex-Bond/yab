#include "../src/devtools_commands.h"
#include <cassert>
#include <iostream>

static int Resolve(const char* name) {
  if (!strcmp(name, "IDC_DEV_TOOLS")) return 700;
  if (!strcmp(name, "IDC_DEV_TOOLS_TOGGLE")) return 901;
  if (!strcmp(name, "IDC_DEV_TOOLS_CONSOLE")) return 702;
  if (!strcmp(name, "IDC_DEV_TOOLS_INSPECT")) return 703;
  return -1;
}
static int Missing(const char*) { return -1; }
int main() {
  using yc::DevToolsCommand;
  assert(!strcmp(DevToolsCommand(700, Resolve), "toggle"));
  assert(!strcmp(DevToolsCommand(901, Resolve), "toggle"));
  assert(!strcmp(DevToolsCommand(702, Resolve), "console"));
  assert(!strcmp(DevToolsCommand(703, Resolve), "inspect"));
  assert(!DevToolsCommand(40004, Resolve)); // No hardcoded SDK numbers.
  assert(!DevToolsCommand(50150, Resolve)); // Copy/edit commands still work.
  assert(!DevToolsCommand(-1, Missing));
  assert(!DevToolsCommand(700, Missing));
  std::cout << "PASS: 8 DevTools command routing assertions\n";
}
