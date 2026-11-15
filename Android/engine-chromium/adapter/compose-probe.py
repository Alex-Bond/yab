#!/usr/bin/env python3
"""Compile only public Compose probe with pinned tools and isolated outputs."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess
import zipfile


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args()
    source = args.source.resolve()
    scratch = args.scratch.resolve()
    if source == scratch or source in scratch.parents or scratch.exists():
        parser.error('Use a fresh scratch directory outside the active source.')
    revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=source, text=True).strip()
    if revision != 'ac19329a1d32108fd05ead15568cb6e188f8615a':
        parser.error('Pinned upstream revision mismatch.')
    for cmd in (['git', 'diff', '--quiet'], ['git', 'diff', '--cached', '--quiet']):
        subprocess.run(cmd, cwd=source, check=True)
    scratch.mkdir(parents=True)
    jars = scratch / 'classes-jars'
    jars.mkdir()
    inputs = []
    classpath = []
    expanded_bytes = 0
    # Use one pinned upstream AndroidX graph. Exclude test artifacts and inspect only classes.jar.
    androidx = source / 'third_party/androidx/cipd/libs'
    for directory in sorted(androidx.iterdir()):
        if not directory.is_dir() or any(s in directory.name for s in ('_test', '_lint', '_benchmark')):
            continue
        for file in sorted(directory.iterdir()):
            if file.suffix == '.aar':
                with zipfile.ZipFile(file) as archive:
                    if 'classes.jar' not in archive.namelist():
                        continue
                    info = archive.getinfo('classes.jar')
                    expanded_bytes += info.file_size
                    if info.file_size > 256 * 1024**2 or expanded_bytes > 512 * 1024**2:
                        raise RuntimeError('Bounded public class extraction limit exceeded.')
                    output = jars / (directory.name + '.jar')
                    output.write_bytes(archive.read(info))
                classpath.append(output)
                inputs.append({'path': str(file.relative_to(source)), 'sha256': sha(file),
                               'classesSha256': sha(output), 'classesBytes': output.stat().st_size})
            elif file.suffix == '.jar':
                classpath.append(file)
                inputs.append({'path': str(file.relative_to(source)), 'sha256': sha(file)})
    kotlin = source / 'third_party/kotlinc/current'
    compiler = kotlin / 'lib/kotlin-compiler.jar'
    plugin = kotlin / 'lib/compose-compiler-plugin.jar'
    stdlib = list((source / 'third_party/android_deps/cipd/libs/org_jetbrains_kotlin_kotlin_stdlib').glob('*.jar'))
    if len(stdlib) != 1:
        raise RuntimeError('Pinned Chromium Kotlin stdlib could not be identified uniquely.')
    android = source / 'third_party/android_sdk/public/platforms/android-37.2/android.jar'
    classpath += [stdlib[0], android]
    for file in (compiler, plugin, stdlib[0], android):
        inputs.append({'path': str(file.relative_to(source)), 'sha256': sha(file)})
    (scratch / 'inputs.json').write_text(json.dumps(inputs, indent=2) + '\n')
    probe = Path(__file__).with_name('YabChromeUiProbe.kt')
    copied = scratch / probe.name
    copied.write_bytes(probe.read_bytes())
    java = source / 'third_party/jdk/current/bin/java'
    compiler_cp = ':'.join(str(p) for p in sorted((kotlin / 'lib').glob('*.jar')))
    command = ['nice', '-n', '10', str(java), '-Xmx768m', '-XX:ActiveProcessorCount=1',
               '-cp', compiler_cp, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
               '-kotlin-home', str(kotlin), '-no-stdlib', '-no-reflect',
               '-jvm-target', '25', '-Xjdk-release=25',
               '-classpath', ':'.join(map(str, classpath)), '-Xplugin=' + str(plugin),
               '-d', str(scratch / 'classes'), str(copied)]
    (scratch / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    log = scratch / 'compiler.log'
    with log.open('w') as output:
        try:
            code = subprocess.run(command, cwd=scratch, stdout=output,
                                  stderr=subprocess.STDOUT, timeout=180).returncode
        except subprocess.TimeoutExpired:
            code = 124
    result = {'upstreamRevision': revision, 'startedAt': started,
              'kotlinVersion': (kotlin / 'build.txt').read_text().strip(),
              'compilerSha256': sha(compiler), 'composePluginSha256': sha(plugin),
              'probeSha256': sha(copied), 'inputManifestSha256': sha(scratch / 'inputs.json'),
              'classpathEntries': len(classpath), 'expandedClassesBytes': expanded_bytes,
              'exitCode': code, 'compiled': code == 0, 'gnTargetBuilt': False,
              'chromeActivityRendered': False, 'privateYabUiCompiled': False,
              'apkBuilt': False, 'sourceUnchanged': False}
    if code == 0:
        classes = sorted((scratch / 'classes').rglob('*.class'))
        if not classes:
            raise RuntimeError('Compiler returned success without class artifacts.')
        result['artifacts'] = [{'path': str(p.relative_to(scratch)), 'bytes': p.stat().st_size,
                                'sha256': sha(p)} for p in classes]
        javap = source / 'third_party/jdk/current/bin/javap'
        probe_class = 'org.chromium.chrome.browser.yab.probe.YabChromeUiProbeKt'
        text = subprocess.check_output([str(javap), '-p', '-classpath', str(scratch / 'classes'),
                                        probe_class], cwd=scratch, text=True, timeout=20)
        (scratch / 'javap.txt').write_text(text)
        result['composeTransformedSignature'] = 'androidx.compose.runtime.Composer' in text
        if not result['composeTransformedSignature']:
            raise RuntimeError('Expected Compose transformation was not observed.')
    for cmd in (['git', 'diff', '--quiet'], ['git', 'diff', '--cached', '--quiet']):
        subprocess.run(cmd, cwd=source, check=True)
    result['sourceUnchanged'] = True
    (scratch / 'receipt.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    return code


if __name__ == '__main__':
    raise SystemExit(main())
