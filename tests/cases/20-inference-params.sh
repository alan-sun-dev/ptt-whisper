source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [B] 推理參數"

t_reset_log; t_run >/dev/null
assert_contains "自動偵測執行緒數 -t" "$(t_args)" "-t "
assert_contains "預設帶 -mc 0"        "$(t_args)" "-mc 0"

t_reset_log; t_run "WHISPER_PROMPT=gRPC, Kubernetes" >/dev/null
assert_contains "prompt 帶入 --prompt" "$(t_args)" "--prompt gRPC, Kubernetes"

t_reset_log; t_run "WHISPER_THREADS=3" >/dev/null
assert_contains "WHISPER_THREADS 覆寫" "$(t_args)" "-t 3"

t_reset_log; t_run "WHISPER_MAX_CONTEXT=64" >/dev/null
assert_contains "WHISPER_MAX_CONTEXT 覆寫" "$(t_args)" "-mc 64"

t_reset_log; t_run "WHISPER_MAX_CONTEXT=999" >/dev/null
assert_not_contains "max_context 超界(>224) → 不帶旗標" "$(t_args)" "-mc"
assert_contains "max_context 超界 → log 警告" "$(t_log)" "invalid WHISPER_MAX_CONTEXT"

t_reset_log; t_run "WHISPER_MAX_CONTEXT=abc" >/dev/null
assert_not_contains "max_context 非數字 → 不帶旗標" "$(t_args)" "-mc"

# ── UTF-8 prompt 截斷 ──────────────────────────────────────
LONG=$(python3 -c "print('詞'*600)")
t_reset_log; t_run "WHISPER_PROMPT=$LONG" >/dev/null
assert_contains "超長 prompt → log 記錄截斷" "$(t_log)" "prompt truncated"
python3 - "$T_ARGLOG" <<'PY' > "$T_DIR/utf8check"
import sys
raw=open(sys.argv[1],'rb').read().strip()
parts=raw.split(b' ')
i=parts.index(b'--prompt'); p=parts[i+1]
try:
    t=p.decode('utf-8'); print("VALID %d %d" % (len(p), len(t)))
except UnicodeDecodeError:
    print("INVALID %d" % len(p))
PY
res=$(cat "$T_DIR/utf8check")
assert_contains "截斷後仍是合法 UTF-8（不切半個中文字）" "$res" "VALID"
assert_contains "截斷後 ≤ 800 bytes" "$res" "798"

# ── 舊版 build：不支援的旗標必須自動略過 ────────────────────
t_reset_log; t_clear_caps
t_run "FAKE_CAPS=threads" "WHISPER_PROMPT=x" "WHISPER_VAD=true" "WHISPER_MAX_CONTEXT=32" >/dev/null
assert_not_contains "舊 build → 不帶 --prompt" "$(t_args)" "--prompt"
assert_not_contains "舊 build → 不帶 --vad"    "$(t_args)" "--vad"
assert_not_contains "舊 build → 不帶 -mc"      "$(t_args)" "-mc"
assert_contains     "舊 build → 仍帶 -t"       "$(t_args)" "-t "

t_teardown; t_summary "B inference params"
