#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export YAB_CHECK_WORLD=download-pipeline
python3 -u scripts/runs/appkit_gate_tests.py \
  --commit "$(git rev-parse HEAD)" \
  --filter 'DownloadPipelineTests|DownloadRequestTests|DownloadFileTests|ImageDownloadTests|HoardDownloadFailureTests|SpaceDownloadFolderTests|PageDownloadEventsTests|DownloadPartTests|BlobDownloadTests|ExtensionDownloadsTests|ExtensionDownloadSourceTests|VideoSaveTests|StageViewDeallocationTests' \
  --no-parallel
