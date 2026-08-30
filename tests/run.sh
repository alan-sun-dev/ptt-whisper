#!/usr/bin/env bash
# PTT Whisper 迴歸測試。不需要真的 whisper.cpp / model / Hammerspoon。
#   ./tests/run.sh              跑全部
#   ./tests/run.sh 50 80        只跑編號開頭符合的
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; TESTS="$REPO/tests"

echo "PTT Whisper regression suite"
echo "  repo:  $REPO"
echo "  bash:  $(/bin/bash --version | head -1)"
echo "  lua:   $(command -v lua || command -v lua5.4 || command -v luajit || echo '(無 — Lua 單元測試會被略過)')"
echo

for tool in python3 curl; do
  command -v "$tool" >/dev/null || { echo "缺少必要工具: $tool"; exit 2; }
done

# ── 靜態檢查 ────────────────────────────────────────────────
echo "  [S] 靜態檢查"
sp=0; sf=0
if /bin/bash -n "$REPO/transcribe.sh" 2>/dev/null; then
  printf '    \033[32m✓\033[0m transcribe.sh 通過 bash 3.2 語法檢查\n'; sp=$((sp+1))
else
  printf '    \033[31m✗\033[0m transcribe.sh 語法錯誤\n'; sf=$((sf+1))
fi
if python3 -c "import json;json.load(open('$REPO/config_example.json'))" 2>/dev/null; then
  printf '    \033[32m✓\033[0m config_example.json 是合法 JSON\n'; sp=$((sp+1))
else
  printf '    \033[31m✗\033[0m config_example.json 不是合法 JSON\n'; sf=$((sf+1))
fi
if python3 "$TESTS/lib/lua_balance.py" "$REPO/ptt_whisper.lua" >/dev/null 2>&1; then
  printf '    \033[32m✓\033[0m ptt_whisper.lua 區塊平衡（非完整語法驗證）\n'; sp=$((sp+1))
else
  printf '    \033[31m✗\033[0m ptt_whisper.lua 區塊不平衡\n'; sf=$((sf+1))
fi
if python3 "$TESTS/lib/config_consistency.py" "$REPO" >/dev/null 2>&1; then
  printf '    \033[32m✓\033[0m 設定欄位在 Lua/README/config_example 三方一致\n'; sp=$((sp+1))
else
  printf '    \033[31m✗\033[0m 設定欄位三方不一致\n'; sf=$((sf+1))
  python3 "$TESTS/lib/config_consistency.py" "$REPO"
fi
echo

TP=0; TF=0; TS=0
for f in "$TESTS"/cases/*.sh; do
  base=$(basename "$f")
  if [[ $# -gt 0 ]]; then
    match=0; for pat in "$@"; do [[ "$base" == "$pat"* ]] && match=1; done
    [[ $match -eq 0 ]] && continue
  fi
  rf=$(mktemp); T_RESULT_FILE="$rf" /bin/bash "$f"
  read -r p fl s < "$rf" 2>/dev/null || { p=0; fl=1; s=0; }
  TP=$((TP+p)); TF=$((TF+fl)); TS=$((TS+s)); rm -f "$rf"
  echo
done

TP=$((TP+sp)); TF=$((TF+sf))
echo "════════════════════════════════════════════"
printf '  TOTAL: \033[32m%d passed\033[0m' "$TP"
(( TF > 0 )) && printf ', \033[31m%d failed\033[0m' "$TF"
(( TS > 0 )) && printf ', \033[33m%d skipped\033[0m' "$TS"
echo; echo "════════════════════════════════════════════"
(( TS > 0 )) && echo "  ⚠️  有略過的項目 — 見 tests/README.md 的「尚未被測到的部分」"
exit $(( TF > 0 ? 1 : 0 ))
