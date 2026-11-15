#include "include/cef_app.h"
#include "include/wrapper/cef_library_loader.h"
#include "media_renderer.h"
#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif
int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox;
  if (!sandbox.Initialize(argc, argv)) return 1;
#endif
  CefScopedLibraryLoader loader;
  if (!loader.LoadInHelper()) return 1;
  return CefExecuteProcess(CefMainArgs(argc, argv), new MediaRenderer, nullptr);
}
