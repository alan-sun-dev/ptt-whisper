#!/usr/bin/env bash
# 測試共用工具：沙箱、斷言、transcribe.sh 呼叫包裝
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS="$REPO/tests"

# 與 ptt_whisper.lua 傳給 transcribe.sh 的 PATH 完全一致。
# 測試必須跑在同一個 PATH 下，否則像「md5 在 /sbin 找不到」這種
# 只在真實 runtime 出現的 bug 永遠測不出來。
RUNTIME_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

T_PASS=0; T_FAIL=0; T_SKIP=0
T_FAILURES=()

_t_ok()   { T_PASS=$((T_PASS+1)); printf '    \033[32m✓\033[0m %s\n' "$1"; }
_t_bad()  { T_FAIL=$((T_FAIL+1)); T_FAILURES+=("$1"); printf '    \033[31m✗\033[0m %s\n' "$1"; }
t_skip()  { T_SKIP=$((T_SKIP+1)); printf '    \033[33m−\033[0m %s (skipped: %s)\n' "$1" "${2:-}"; }

assert_eq() { # <name> <actual> <expected>
  if [[ "$2" == "$3" ]]; then _t_ok "$1"
  else _t_bad "$1"; printf '        expected: %q\n        actual:   %q\n' "$3" "$2"; fi
}
assert_contains() { # <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then _t_ok "$1"
  else _t_bad "$1"; printf '        expected to contain: %q\n        actual: %q\n' "$3" "$2"; fi
}
assert_not_contains() { # <name> <haystack> <needle>
  if [[ "$2" != *"$3"* ]]; then _t_ok "$1"
  else _t_bad "$1"; printf '        expected NOT to contain: %q\n        actual: %q\n' "$3" "$2"; fi
}
assert_file_has() { # <name> <file> <needle>
  local c=""; [[ -f "$2" ]] && c=$(cat "$2")
  assert_contains "$1" "$c" "$3"
}

# ── 沙箱 ──────────────────────────────────────────────────────
t_sandbox() {
  T_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ptt-test-XXXXXX")
  T_HOME="$T_DIR/home";  mkdir -p "$T_HOME"
  T_WD="$T_DIR/whisper.cpp"; mkdir -p "$T_WD/models"
  T_ARGLOG="$T_DIR/arglog"; : > "$T_ARGLOG"
  T_REQLOG="$T_DIR/reqlog"; : > "$T_REQLOG"
  T_PTT="$T_HOME/.ptt-whisper"
  cp "$TESTS/fakes/fake-whisper-cli" "$T_WD/whisper-cli"
  chmod +x "$T_WD/whisper-cli"
  WAV="$TESTS/fixtures/silence-16k-1s.wav"
}
t_teardown() { [[ -n "${T_DIR:-}" && -d "$T_DIR" ]] && rm -rf "$T_DIR"; }

t_model() { : > "$T_WD/models/$1"; printf 'x%.0s' $(seq 1 64) >> "$T_WD/models/$1"; }
t_reset_log() { : > "$T_ARGLOG"; : > "$T_REQLOG"; }

# t_run [ENV=val ...] [-- transcribe.sh 參數]
t_run() {
  local envs=()
  while [[ $# -gt 0 && "$1" == *=* && "$1" != /* ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  # bash 3.2 + set -u：空陣列必須用 ${a[@]+"${a[@]}"} 展開，否則 unbound variable
  env -i HOME="$T_HOME" PATH="$RUNTIME_PATH" WHISPER_DIR="$T_WD" \
      FAKE_ARGLOG="$T_ARGLOG" ${envs[@]+"${envs[@]}"} \
      /bin/bash "$REPO/transcribe.sh" "${@:-$WAV}" 2>"$T_DIR/stderr"
}
t_args()   { cat "$T_ARGLOG"; }
t_stderr() { cat "$T_DIR/stderr" 2>/dev/null || true; }
t_log()    { cat "$T_PTT/ptt_whisper_err.log" 2>/dev/null || true; }
# grep -c 在 0 筆時「已經印出 0」但 exit 1；用 || echo 0 會多印一行。
t_count()  { local n; n=$(grep -c . "$1" 2>/dev/null || true); echo "${n:-0}"; }
t_runs()   { t_count "$T_ARGLOG"; }
# 清掉 whisper 能力偵測快取。快取 key 是 binary 的 path+mtime+size，
# 測試改的是 FAKE_CAPS 環境變數、binary 沒變，所以必須手動清掉才會重新偵測。
t_clear_caps() { rm -f "$T_PTT/whisper_caps.txt"; }

t_summary() {
  echo
  printf '  %s: \033[32m%d passed\033[0m' "$1" "$T_PASS"
  (( T_FAIL > 0 )) && printf ', \033[31m%d failed\033[0m' "$T_FAIL"
  (( T_SKIP > 0 )) && printf ', \033[33m%d skipped\033[0m' "$T_SKIP"
  echo
  printf '%d %d %d\n' "$T_PASS" "$T_FAIL" "$T_SKIP" > "${T_RESULT_FILE:-/dev/null}"
  (( T_FAIL == 0 ))
}

# ── 假 server 控制 ───────────────────────────────────────────
T_PORT=8179
t_server_start() { # t_server_start [health_mode] [infer_mode]
  FAKE_HEALTH_MODE="${1:-ok}" FAKE_INFER_MODE="${2:-ok}" FAKE_REQLOG="$T_REQLOG" \
    python3 "$TESTS/fakes/fake-whisper-server.py" "$T_PORT" &
  T_SRV_PID=$!
  for _ in $(seq 1 40); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$T_PORT/health" && break
    sleep 0.1
  done
}
t_server_stop() {
  [[ -n "${T_SRV_PID:-}" ]] && kill "$T_SRV_PID" 2>/dev/null
  wait "${T_SRV_PID:-}" 2>/dev/null
  T_SRV_PID=""
  for _ in $(seq 1 30); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$T_PORT/health" || break
    sleep 0.1
  done
}
t_server_url() { echo "http://127.0.0.1:$T_PORT"; }
t_req_fields() { python3 -c "
import json,sys
try: d=json.loads(open('$T_REQLOG').readline())
except Exception: print('{}'); sys.exit()
print(json.dumps(d['fields'],ensure_ascii=False))"; }
t_req_field() { python3 -c "
import json,sys
try: d=json.loads(open('$T_REQLOG').readline())
except Exception: sys.exit()
print(d['fields'].get('$1',''))"; }
t_req_count() { t_count "$T_REQLOG"; }
