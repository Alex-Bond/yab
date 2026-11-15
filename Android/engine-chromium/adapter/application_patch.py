"""Real early Chrome Application hook; private Yab application sources are not inputs."""
from pathlib import Path


def extend_application(source, changes, modify):
    path = 'chrome/android/java/src/org/chromium/chrome/browser/yab/YabChromeBootstrap.java'
    if (source / path).exists():
        raise RuntimeError('Existing application adapter must be preserved.')
    changes[path] = (Path(__file__).parent / 'YabChromeBootstrap.java').read_text()
    modify('chrome/android/chrome_java_sources.gni',
           '  "java/src/org/chromium/chrome/browser/yab/YabChromeSession.java",\n',
           '  "java/src/org/chromium/chrome/browser/yab/YabChromeBootstrap.java",\n'
           '  "java/src/org/chromium/chrome/browser/yab/YabChromeSession.java",\n')
    app = 'chrome/android/java/src/org/chromium/chrome/browser/ChromeApplicationImpl.java'
    modify(app, 'import org.chromium.chrome.browser.profiles.ProfileResolver;\n',
           'import org.chromium.chrome.browser.profiles.ProfileResolver;\n'
           'import org.chromium.chrome.browser.yab.YabChromeBootstrap;\n')
    modify(app, '        assert SplitCompatApplication.isBrowserProcess();\n',
           '        assert SplitCompatApplication.isBrowserProcess();\n'
           '        YabChromeBootstrap.onApplicationCreate(getApplication());\n')
    creator = 'chrome/android/java/src/org/chromium/chrome/browser/tabmodel/ChromeTabCreator.java'
    modify(creator, 'import org.chromium.chrome.browser.tab.YabNamespaceRuntime;\n',
           'import org.chromium.chrome.browser.tab.YabNamespaceRuntime;\n'
           'import org.chromium.chrome.browser.yab.YabChromeBootstrap;\n')
    modify(creator, '        if (!YabNamespaceRuntime.canRestore(getProfile(), id, state)) return null;\n',
           '        if (!YabChromeBootstrap.ensureProfile(getProfile())\n'
           '                || !YabNamespaceRuntime.canRestore(getProfile(), id, state)) return null;\n')

    # onNativeDestroyed runs inside Profile::~Profile, before the BrowserContext
    # base destructor. Mark completion only after the owning erase has returned.
    profile = 'chrome/browser/profiles/android/java/src/org/chromium/chrome/browser/profiles/Profile.java'
    modify(profile, '    private boolean mDestroyNotified;\n',
           '    private boolean mDestroyNotified;\n'
           '    private boolean mYabOffTheRecordDestructionComplete;\n')
    modify(profile, '    @CalledByNative\n    private long getNativePointer() {\n', '''    /** Only the explicit post-destruction native hook can complete Private teardown. */
    public boolean isYabOffTheRecordDestructionComplete() {
        return isOffTheRecord() && mNativeProfile == 0 && mYabOffTheRecordDestructionComplete;
    }

    @CalledByNative
    private void onYabOffTheRecordDestructionCompleted() {
        if (!isOffTheRecord() || mNativeProfile != 0) {
            throw new IllegalStateException("OTR completion preceded native Profile destruction");
        }
        mYabOffTheRecordDestructionComplete = true;
    }

    @CalledByNative
    private long getNativePointer() {
''')
    destroyer = 'chrome/browser/profiles/profile_destroyer.cc'
    modify(destroyer, '#include "content/public/browser/render_process_host.h"\n',
           '#include "content/public/browser/render_process_host.h"\n\n'
           '#if BUILDFLAG(IS_ANDROID)\n'
           '#include "base/android/jni_android.h"\n'
           '// After headers specializing JNI conversions.\n'
           '#include "chrome/browser/profiles/android/jni_headers/Profile_jni.h"\n'
           '#endif\n')
    modify(destroyer,
           '  CHECK(profile->GetOriginalProfile(), base::NotFatalUntil::M162);\n'
           '  profile->GetOriginalProfile()->DestroyOffTheRecordProfile(profile);\n',
           '  CHECK(profile->GetOriginalProfile(), base::NotFatalUntil::M162);\n'
           '#if BUILDFLAG(IS_ANDROID)\n'
           '  JNIEnv* env = jni_zero::AttachCurrentThread();\n'
           '  auto java_profile = profile->GetJavaObject();\n'
           '#endif\n'
           '  profile->GetOriginalProfile()->DestroyOffTheRecordProfile(profile);\n'
           '#if BUILDFLAG(IS_ANDROID)\n'
           '  // ProfileImpl erases its owning unique_ptr and completes incognito preference cleanup.\n'
           '  // The Profile/BrowserContext destructor stack has returned. Never dereference profile.\n'
           '  Java_Profile_onYabOffTheRecordDestructionCompleted(env, java_profile);\n'
           '#endif\n')
    modify('chrome/browser/profiles/BUILD.gn',
           '  if (enable_extensions) {\n'
           '    deps += [ "//chrome/browser/extensions" ]\n'
           '  }\n\n'
           '  if (!is_android) {\n'
           '    sources += [\n'
           '      "delete_profile_helper.cc",\n',
           '  if (enable_extensions) {\n'
           '    deps += [ "//chrome/browser/extensions" ]\n'
           '  }\n\n'
           '  if (is_android) {\n'
           '    deps += [ "//chrome/browser/profiles/android:jni_headers" ]\n'
           '  }\n\n'
           '  if (!is_android) {\n'
           '    sources += [\n'
           '      "delete_profile_helper.cc",\n')
