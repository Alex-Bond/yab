// The GPU, Plugin, Alerts and plain helper, as Chromium's helper is: a C main
// that enters the sandbox, loads the framework and hands the process to it.
// It links libSystem alone and exports nothing of its own, no Objective-C, no
// C++ runtime, no CEF wrapper: everything a utility, GPU or notification
// process does is the framework's. Only the renderer has a CefApp of Yab's
// (helper.mm, MediaRenderer), so only it carries the C++ wrapper.
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <string.h>

#include "include/capi/cef_app_capi.h"
#include "include/cef_api_hash.h"

#if defined(YAB_ALERTS_HELPER)
// site_notice_center.mm: only in the Alerts helper.
extern void yc_notices_install_in_alerts_helper(int argc, char* argv[]);
#endif

// Next to the helper's app, as CEF's own loaders find them.
static const char kSandbox[] = "/../../../Chromium Embedded Framework.framework/Libraries/libcef_sandbox.dylib";
static const char kFramework[] = "/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework";

static int Beside(const char* relative, char* out, size_t size) {
  char exe[PATH_MAX];
  uint32_t length = sizeof(exe);
  if (_NSGetExecutablePath(exe, &length) != 0) return 0;
  const char* folder = dirname(exe);
  return folder && snprintf(out, size, "%s%s", folder, relative) < (int)size;
}

static void* Open(const char* relative) {
  char path[PATH_MAX];
  if (!Beside(relative, path, sizeof(path))) {
    fprintf(stderr, "YabCore helper: no bundle around %s\n", relative);
    return NULL;
  }
  void* library = dlopen(path, RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!library) fprintf(stderr, "YabCore helper: dlopen %s: %s\n", path, dlerror());
  return library;
}

int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  // Before the framework loads, as cefsimple's helper does. The context
  // lives as long as the process.
  void* sandbox = Open(kSandbox);
  void* (*initialize)(int, char**) = sandbox ? (void* (*)(int, char**))dlsym(sandbox, "cef_sandbox_initialize") : NULL;
  if (!initialize || !initialize(argc, argv)) return 1;
#endif
  void* framework = Open(kFramework);
  if (!framework) return 1;
  const char* (*hash)(int, int) = (const char* (*)(int, int))dlsym(framework, "cef_api_hash");
  int (*execute)(const cef_main_args_t*, cef_app_t*, void*) =
      (int (*)(const cef_main_args_t*, cef_app_t*, void*))dlsym(framework, "cef_execute_process");
  if (!hash || !execute) {
    fprintf(stderr, "YabCore helper: %s\n", dlerror());
    return 1;
  }
  // Sets the API version the framework speaks with this process, as the
  // wrapper's CefExecuteProcess does first.
  const char* spoken = hash(CEF_API_VERSION, 0);
  if (!spoken || strcmp(spoken, CEF_API_HASH_PLATFORM) != 0) {
    fprintf(stderr, "YabCore helper: framework API %s, helper built for %s\n", spoken ? spoken : "(none)", CEF_API_HASH_PLATFORM);
    return 1;
  }
#if defined(YAB_ALERTS_HELPER)
  yc_notices_install_in_alerts_helper(argc, argv);
#endif
  cef_main_args_t args = {argc, argv};
  return execute(&args, NULL, NULL);
}
