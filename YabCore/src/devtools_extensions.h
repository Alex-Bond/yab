#pragma once
#include <string>

namespace yc {
// Chrome's DevToolsWindow::OnLoadCompleted seeds this before extensions are
// initialized. Our ordinary-page frontend has no DevToolsWindow delegate.
// Supply the *native* inspected tab ID through the same stock frontend API,
// before ExtensionServer builds chrome.devtools for each extension frame.
inline std::string DevToolsExtensionIdentity(int tab) {
  if (tab <= 0) return {};
  return R"JS((()=>{
    if (self !== top || location.origin !== 'devtools://devtools') return;
    const seed = api => {
      if (typeof api?.setInspectedTabId === 'function') api.setInspectedTabId()JS" + std::to_string(tab) + R"JS();
    };
    let current = globalThis.DevToolsAPI;
    // The native compatibility bootstrap can replace this object after a
    // document-start script. Seed each replacement before its extensions load.
    Object.defineProperty(globalThis, 'DevToolsAPI', {
      configurable: true, enumerable: true,
      get() { return current; },
      set(api) { current = api; seed(api); }
    });
    seed(current);
  })())JS";
}
}
