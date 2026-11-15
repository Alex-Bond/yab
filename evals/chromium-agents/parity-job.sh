#!/bin/bash
# One signed build for the full primitive set, lifecycle and original agent UIs.
set -euo pipefail
cd "$(dirname "$0")/../.."
RESULT=0
bash evals/chromium-agents/merge-job.sh --with-lifecycle --only button,react-form,editor,combobox,hover-menu,covered,shadow,iframe-cross,iframe-user,delayed,virtual,drag,upload,download,nodownload,cardmask,reply,dialog,popup,palette,seen,csp,stale --security --geometry --url-download || RESULT=1
if [[ -s "$YAB_FARM_OUT/yab-app-path.txt" ]]; then
    APP="$(cat "$YAB_FARM_OUT/yab-app-path.txt")"
    python3 -u evals/chromium-agents/sweep.py --app "$APP" --out "$YAB_FARM_OUT/sweep" --only made,row,providers,gemini-connect,cli-launch,plaque,face-slide,row-hush,needs-user,cleanup-focused || RESULT=1
    mkdir -p "$YAB_FARM_OUT/extra"
    # Independent mail proof must precede original suites that may wait for
    # the person's real provider sign-in. Their original assertions remain.
    python3 -u evals/chromium-agents/mail_pair.py --app "$APP" --out "$YAB_FARM_OUT/mail-code" || RESULT=1
    YAB_FARM_OUT="$YAB_FARM_OUT/extra" bash evals/chromium-agents/extra-job.sh --app "$APP" || RESULT=1
fi
exit "$RESULT"
