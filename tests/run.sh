#!/usr/bin/env bash
# PTT Whisper 迴歸測試。不需要真的 whisper.cpp / model / Hammerspoon。
#
#   ./tests/run.sh              完整 merge-gate 測試
#   ./tests/run.sh 50 80        只跑編號開頭符合的
#
#   PTT_TEST_ALLOW_MISSING_DEPS=1 ./tests/run.sh
#       容忍缺少可選依賴（lua / ffmpeg / ffprobe）。
#       這會把該次執行降級為 PARTIAL，「不」滿足 merge gate。
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"; TESTS="$REPO/tests"

ALLOW_MISSING="${PTT_TEST_ALLOW_MISSING_DEPS:-0}"
export ALLOW_MISSING

red()  { printf '\033[31m%s\033[0m' "$1"; }
grn()  { printf '\033[32m%s\033[0m' "$1"; }
ylw()  { printf '\033[33m%s\033[0m' "$1"; }

# ── 硬性依賴：缺了連測試框架都跑不起來 ──────────────────────
for tool in python3 curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$(red "缺少必要工具: $tool")"
    echo "RESULT: FAIL"
    exit 2
  fi
done

# ── merge-gate 依賴：缺了會產生 skip，預設視為失敗 ──────────
LUA_BIN=""
for c in lua lua5.4 lua5.3 luajit; do
  command -v "$c" >/dev/null 2>&1 && { LUA_BIN="$c"; break; }
done
export LUA_BIN

MISSING=()
[[ -z "$LUA_BIN" ]] && MISSING+=("lua")
command -v ffmpeg  >/dev/null 2>&1 || MISSING+=("ffmpeg")
command -v ffprobe >/dev/null 2>&1 || MISSING+=("ffprobe")

echo "PTT Whisper regression suite"
echo "  repo:  $REPO"
echo "  bash:  $(/bin/bash --version | head -1)"
echo "  lua:   ${LUA_BIN:-(未安裝)}"
echo

if [[ ${#MISSING[@]} -gt 0 ]]; then
  if [[ "$ALLOW_MISSING" == "1" ]]; then
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│ $(ylw "WARNING: 已明確略過缺少的依賴")                                 │"
    echo "│                                                              │"
    printf  "│   缺少: %-53s│\n" "${MISSING[*]}"
    echo "│                                                              │"
    echo "│ $(ylw "本次執行「不」滿足完整 merge gate。")                             │"
    echo "│ $(ylw "相關測試不會被執行，結果不足以作為合併依據。")                   │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo
  else
    echo "$(red "缺少 merge-gate 所需的依賴: ${MISSING[*]}")"
    echo
    echo "  這些依賴缺席會讓部分測試無法執行。特別是 lua——"
    echo "  classifyHealthResponse 的實際出貨程式碼若沒有被執行，"
    echo "  整套 regression suite 不應被視為完整通過。"
    echo
    echo "  macOS 安裝："
    [[ -z "$LUA_BIN" ]] && echo "      brew install lua"
    command -v ffmpeg >/dev/null 2>&1 || echo "      brew install ffmpeg"
    echo
    echo "  若你只想跑 shell 部分的迴歸測試（不足以作為合併依據）："
    echo "      PTT_TEST_ALLOW_MISSING_DEPS=1 ./tests/run.sh"
    echo
    echo "RESULT: FAIL"
    exit 1
  fi
fi

# ── 靜態檢查 ────────────────────────────────────────────────
echo "  [S] 靜態檢查"
sp=0; sf=0
_s_ok()  { printf '    \033[32m✓\033[0m %s\n' "$1"; sp=$((sp+1)); }
_s_bad() { printf '    \033[31m✗\033[0m %s\n' "$1"; sf=$((sf+1)); }
/bin/bash -n "$REPO/transcribe.sh" 2>/dev/null \
  && _s_ok "transcribe.sh 通過 bash 3.2 語法檢查" \
  || _s_bad "transcribe.sh 語法錯誤"
python3 -c "import json;json.load(open('$REPO/config_example.json'))" 2>/dev/null \
  && _s_ok "config_example.json 是合法 JSON" \
  || _s_bad "config_example.json 不是合法 JSON"
python3 "$TESTS/lib/lua_balance.py" "$REPO/ptt_whisper.lua" >/dev/null 2>&1 \
  && _s_ok "ptt_whisper.lua 區塊平衡（非完整語法驗證）" \
  || _s_bad "ptt_whisper.lua 區塊不平衡"
if python3 "$TESTS/lib/shell_var_scan.py" "$REPO/transcribe.sh" "$TESTS/run.sh" \
     "$TESTS/lib/common.sh" "$TESTS"/cases/*.sh "$TESTS/fakes/fake-whisper-cli" \
     >/dev/null 2>&1; then
  _s_ok "shell 檔案無「\$VAR 緊接非 ASCII 字元」的寫法"
else
  _s_bad "有 \$VAR 緊接非 ASCII 字元（bash 會把多位元組吃進變數名）"
  python3 "$TESTS/lib/shell_var_scan.py" "$REPO/transcribe.sh" "$TESTS/run.sh" \
     "$TESTS/lib/common.sh" "$TESTS"/cases/*.sh "$TESTS/fakes/fake-whisper-cli"
fi
if python3 "$TESTS/lib/config_consistency.py" "$REPO" >/dev/null 2>&1; then
  _s_ok "設定欄位在 Lua/README/config_example 三方一致"
else
  _s_bad "設定欄位三方不一致"; python3 "$TESTS/lib/config_consistency.py" "$REPO"
fi
echo

# ── 各主題測試 ──────────────────────────────────────────────
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

# ── 結果 ────────────────────────────────────────────────────
echo "════════════════════════════════════════════"
printf '  %s' "$(grn "$TP passed")"
(( TF > 0 )) && printf ', %s' "$(red "$TF failed")"
(( TS > 0 )) && printf ', %s' "$(ylw "$TS skipped")"
echo

# merge gate 的實質要求就是「0 failed 且 0 skipped」。
# skip 不只可能來自 lua，所以這裡用統一規則判斷，而不是只針對 lua。
if (( TF > 0 )); then
  RESULT="FAIL"; CODE=1; NOTE=""
elif (( TS > 0 )); then
  if [[ "$ALLOW_MISSING" == "1" ]]; then
    RESULT="PARTIAL"; CODE=0; NOTE="  (NOT merge-gate compliant — 有測試未執行)"
  else
    RESULT="FAIL"; CODE=1
    NOTE="  (有測試被略過；merge gate 要求 0 skipped)"
  fi
else
  RESULT="PASS"; CODE=0; NOTE="  (merge-gate compliant)"
fi

case "$RESULT" in
  PASS)    echo "  RESULT: $(grn "PASS")$NOTE" ;;
  PARTIAL) echo "  RESULT: $(ylw "PARTIAL")$NOTE" ;;
  FAIL)    echo "  RESULT: $(red "FAIL")$NOTE" ;;
esac
echo "════════════════════════════════════════════"
# 這一行刻意保持純文字，方便腳本 grep：
echo "RESULT: $RESULT"
exit $CODE
