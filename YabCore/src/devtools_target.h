#pragma once
#include <string>

namespace yc {
// Match Chrome's frontend to the attached CDP target. A tab target has no
// DOM of its own; its page arrives through Target.setAutoAttach. Workers use
// the worker frontend so Console/Sources do not wait for a Page domain.
inline std::string DevToolsFrontend(const std::string& type) {
  if (type == "service_worker" || type == "shared_worker" || type == "worker")
    return "worker_app.html";
  return "devtools_app.html";
}
inline std::string DevToolsTargetQuery(const std::string& type) {
  return type == "tab" ? "&targetType=tab" : "";
}
}
