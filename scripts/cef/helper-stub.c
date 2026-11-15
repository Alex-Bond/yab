// Packaging smoke test only. The YabCore track supplies the real CEF host.
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void) {
    char executable[PATH_MAX], resolved[PATH_MAX], framework[PATH_MAX];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) || !realpath(executable, resolved)) return 1;
    char *slash = strrchr(resolved, '/');
    if (!slash) return 1;
    *slash = 0;
    snprintf(framework, sizeof(framework), "%s/../../../Chromium Embedded Framework.framework/Chromium Embedded Framework", resolved);
    void *library = dlopen(framework, RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "YabCore packaging stub: %s\n", dlerror()); return 1; }
    int (*version)(int) = (int (*)(int))dlsym(library, "cef_version_info");
    if (!version || version(0) != 156) return 1;
    printf("YabCore packaging stub started inside bundle; CEF %d loaded\n", version(0));
    return 0;
}
