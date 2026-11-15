#pragma once
#include <string>

namespace yc {
// An ordinary devtools:// page has compatibility bindings, but no
// DevToolsWindow to service save/append. Keep the stock FileManager contract;
// only those two host methods cross our native binding.
inline std::string DevToolsFileBridge() {
  return R"JS((()=>{
    if (self !== top || location.origin !== 'devtools://devtools') return;
    const connect = host => {
      if (!host) return;
      host.save = (url, content, forceSaveAs, isBase64) =>
        yabDevToolsFile(JSON.stringify({method:'save', url, content, forceSaveAs, isBase64}));
      host.append = (url, content) =>
        yabDevToolsFile(JSON.stringify({method:'append', url, content}));
    };
    let current = globalThis.InspectorFrontendHost;
    Object.defineProperty(globalThis, 'InspectorFrontendHost', {
      configurable:true, enumerable:true,
      get() { return current; },
      set(host) { current = host; connect(host); }
    });
    connect(current);
  })())JS";
}
}
