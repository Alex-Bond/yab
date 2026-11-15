#!/usr/bin/env python3
"""Run the complete production Reader script/theme tests in a small package."""
import os
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[2]
package = Path(os.environ['YAB_FARM_OUT']) / 'reader-unit'
(package / 'Sources/Fast').mkdir(parents=True, exist_ok=True)
(package / 'Tests/FastTests').mkdir(parents=True, exist_ok=True)
(package / 'Package.swift').write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ReaderChecks", platforms: [.macOS("15.4")], targets: [
    .target(name: "Fast", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "FastTests", dependencies: ["Fast"], swiftSettings: [.swiftLanguageMode(.v5)])
])
''')
for name in ('Reader.swift', 'ReaderThemes.swift'):
    shutil.copy2(root / 'Sources/Fast' / name, package / 'Sources/Fast' / name)
for name in ('ReaderTests.swift', 'ReaderStyleTests.swift'):
    shutil.copy2(root / 'Tests/FastTests' / name, package / 'Tests/FastTests' / name)
subprocess.run(['swift', 'test', '--package-path', str(package), '--jobs', '2'], check=True)
