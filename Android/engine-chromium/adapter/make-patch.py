#!/usr/bin/env python3
"""Read the pinned upstream tree and write an unapplied source scaffold patch.

Only the output file is written. This script never modifies Chromium source,
GN configuration, generated build files, or the running baseline build.
"""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess

from namespace_patch import extend
from application_patch import extend_application
from cookies_patch import extend_cookies


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    output = args.output.resolve()
    if source == output or source in output.parents:
        parser.error('The patch output must be outside the active Chromium tree.')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != 'ac19329a1d32108fd05ead15568cb6e188f8615a':
        parser.error('The source must match the exact reviewed upstream revision.')
    changes = {}

    def modify(path, before, after):
        original = (source / path).read_text()
        current = changes.get(path, original)
        if current.count(before) != 1:
            raise RuntimeError('Unexpected pinned source anchor in ' + path)
        changes[path] = current.replace(before, after)

    java = 'chrome/browser/android/content/java/src/org/chromium/chrome/browser/content/WebContentsFactory.java'
    modify(java, 'import org.chromium.base.ResettersForTesting;\n',
           'import org.chromium.base.ResettersForTesting;\nimport org.chromium.base.ThreadUtils;\n')
    modify(java, 'import org.chromium.net.NetId;\n',
           'import org.chromium.net.NetId;\n\nimport java.util.UUID;\n')
    method = '''    /** Native-owned, non-default namespace; lifetime belongs to the host's namespace lease. */
    public static WebContents createWebContentsForYabNamespace(
            Profile profile, String namespaceId, boolean inMemory) {
        return createWebContentsForYabNamespace(profile, namespaceId, inMemory, true, true);
    }

    public static WebContents createWebContentsForYabNamespace(Profile profile,
            String namespaceId, boolean inMemory, boolean initiallyHidden, boolean initializeRenderer) {
        ThreadUtils.assertOnUiThread();
        if (!UUID.fromString(namespaceId).toString().equals(namespaceId)) {
            throw new IllegalArgumentException("Namespace ID must be a canonical lowercase UUID");
        }
        if (profile.isOffTheRecord() && !inMemory) {
            throw new IllegalArgumentException("Off-the-record namespaces must stay in memory");
        }
        @Nullable WebContents contents = WebContentsFactoryJni.get().createWebContentsForYabNamespace(
                profile, namespaceId, inMemory, initiallyHidden, initializeRenderer);
        if (contents == null) throw new IllegalStateException("Native namespace factory refused the input");
        return contents;
    }

'''
    modify(java, '    @NativeMethods\n', method + '    @NativeMethods\n')
    modify(java, '    public interface Natives {\n', '''    public interface Natives {
        @Nullable WebContents createWebContentsForYabNamespace(
                @JniType("Profile*") Profile profile,
                @JniType("std::string") String namespaceId, boolean inMemory,
                boolean initiallyHidden, boolean initializeRenderer);

''')

    cpp = 'chrome/browser/android/content/web_contents_factory.cc'
    modify(cpp, '#include "base/android/jni_android.h"\n',
           '#include <string>\n\n#include "base/android/jni_android.h"\n#include "base/android/jni_string.h"\n#include "base/uuid.h"\n')
    native = '''static ScopedJavaLocalRef<jobject>
JNI_WebContentsFactory_CreateWebContentsForYabNamespace(
    JNIEnv* env,
    Profile* profile,
    const std::string& namespace_id,
    bool in_memory,
    bool initially_hidden,
    bool initialize_renderer) {
  const base::Uuid id = base::Uuid::ParseLowercase(namespace_id);
  if (!profile || !id.is_valid() || (profile->IsOffTheRecord() && !in_memory)) {
    return {};
  }
  const auto partition = content::StoragePartitionConfig::Create(
      profile, "YabWebsiteNamespace", id.AsLowercaseString(), in_memory);
  auto site_instance = content::SiteInstance::CreateForFixedStoragePartition(
      profile, GURL(), partition);
  content::WebContents::CreateParams params(profile, std::move(site_instance));
  params.initially_hidden = initially_hidden;
  params.desired_renderer_state = initialize_renderer
      ? content::WebContents::CreateParams::kInitializeAndWarmupRendererProcess
      : content::WebContents::CreateParams::kNoRendererProcess;
  // A partition can be shared by multiple tabs. Do not attach the experiment's
  // per-WebContents data deleter; namespace disposal needs a separate lease.
  auto contents = content::WebContents::Create(params);
  auto java_contents = contents->GetJavaWebContents();
  if (java_contents.is_null()) return {};
  contents.release();
  return java_contents;
}

'''
    modify(cpp, 'static ScopedJavaLocalRef<jobject> JNI_WebContentsFactory_CreateWebContents(\n',
           native + 'static ScopedJavaLocalRef<jobject> JNI_WebContentsFactory_CreateWebContents(\n')
    facade = 'chrome/android/java/src/org/chromium/chrome/browser/yab/YabChromeSession.java'
    if (source / facade).exists():
        raise RuntimeError('Existing adapter source must be preserved.')
    changes[facade] = (Path(__file__).parent / 'YabChromeSession.java').read_text()
    gn = 'chrome/android/chrome_java_sources.gni'
    modify(gn, 'chrome_java_sources = [\n',
           'chrome_java_sources = [\n  "java/src/org/chromium/chrome/browser/yab/YabChromeSession.java",\n')

    extend(source, changes, modify)
    extend_application(source, changes, modify)
    extend_cookies(source, changes, modify)

    patches = []
    inputs = []
    for path, updated in sorted(changes.items()):
        original = (source / path).read_text() if (source / path).exists() else ''
        patches.append(''.join(difflib.unified_diff(original.splitlines(keepends=True),
                        updated.splitlines(keepends=True),
                        fromfile='a/' + path if original else '/dev/null', tofile='b/' + path)))
        inputs.append({'path': path, 'originalSha256': hashlib.sha256(original.encode()).hexdigest(),
                       'proposedSha256': hashlib.sha256(updated.encode()).hexdigest()})
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(''.join(patches))
    receipt = {'upstreamRevision': revision, 'applied': False, 'compiled': False,
               'runtimeVerified': False, 'parityAcceptance': False,
               'patchSha256': hashlib.sha256(output.read_bytes()).hexdigest(), 'files': inputs}
    output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps({k: v for k, v in receipt.items() if k != 'files'}))


if __name__ == '__main__':
    main()
