#!/bin/bash
# What the real CLIs do with only a key, in a HOME of their own, with a key
# no provider knows (docs/agents.md, Use an API Key): claude -p must use
# ANTHROPIC_API_KEY with no question and fail as an invalid key; `codex
# login --with-api-key` must keep the key from stdin in auth.json.
#   ./farm exec --host adhd --pin "claude and codex CLIs" -- bash evals/agent-key/cli_probe.sh
OUT="${YAB_FARM_OUT:-$(mktemp -d)}"
export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
for d in "$HOME"/.nvm/versions/node/*/bin; do PATH="$PATH:$d"; done
C=$(command -v claude); X=$(command -v codex)
echo "claude=$C codex=$X"
KEY=sk-ant-api03-bogus0000000000000000000000000000
H="$OUT/home"; mkdir -p "$H"
if [ -n "$C" ]; then
  "$C" --version
  echo "--- auth status with the key"
  env -i PATH="$PATH" HOME="$H" ANTHROPIC_API_KEY=$KEY "$C" auth status; echo "code=$?"
  echo "--- claude -p with the key, stdin closed, 90 s at most"
  env -i PATH="$PATH" HOME="$H" ANTHROPIC_API_KEY=$KEY /usr/bin/perl -e 'alarm 90; exec @ARGV' "$C" -p "say hi" --output-format json </dev/null; echo "code=$?"
  echo "--- what it wrote"
  ls -la "$H"
  /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: d[k] for k in d if "pi" in k.lower() or "key" in k.lower()})' "$H/.claude.json" 2>&1
fi
if [ -n "$X" ]; then
  "$X" --version
  CX="$OUT/codex"; mkdir -p "$CX"
  echo "--- codex login --with-api-key"
  printf 'sk-bogus123\n' | env -i PATH="$PATH" HOME="$H" CODEX_HOME="$CX" "$X" login --with-api-key; echo "code=$?"
  /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print({k: (v[:6]+"…" if isinstance(v,str) else v) for k,v in d.items()})' "$CX/auth.json"
  env -i PATH="$PATH" HOME="$H" CODEX_HOME="$CX" "$X" login status; echo "code=$?"
  env -i PATH="$PATH" HOME="$H" CODEX_HOME="$CX" "$X" logout; echo "code=$?"
  ls -la "$CX"
fi
