source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [C] VAD"

t_reset_log; t_run >/dev/null
assert_not_contains "無 VAD model → auto 不啟用" "$(t_args)" "--vad"

t_model ggml-silero-v5.1.2.bin
t_reset_log; t_run >/dev/null
assert_contains "有 VAD model → auto 自動啟用" "$(t_args)" "--vad --vad-model"
assert_contains "VAD model 路徑正確" "$(t_args)" "ggml-silero-v5.1.2.bin"

t_reset_log; t_run "WHISPER_VAD=false" >/dev/null
assert_not_contains "vad=false → 不啟用" "$(t_args)" "--vad"

t_reset_log; t_clear_caps
t_run "FAKE_CAPS=threads max-context prompt" "WHISPER_VAD=true" >/dev/null
assert_not_contains "build 不支援 → 不啟用" "$(t_args)" "--vad"
assert_contains     "build 不支援 + 明確要求 → log 警告" "$(t_log)" "no --vad"

t_clear_caps; t_reset_log; t_run "WHISPER_VAD=maybe" >/dev/null
assert_contains "非法 WHISPER_VAD → log 警告" "$(t_log)" "invalid WHISPER_VAD"

# ── VAD 執行失敗 → 同一主模型關 VAD 重試 ────────────────────
t_reset_log
out=$(t_run "FAKE_FAIL_ON_VAD=1" "FAKE_ECHO_MODEL=1")
assert_eq       "VAD 失敗後仍成功轉錄" "$out" "from:ggml-small-q5_1.bin"
assert_eq       "跑了兩次（帶 VAD → 不帶 VAD）" "$(t_runs)" "2"
assert_contains "第一次帶 VAD" "$(sed -n 1p "$T_ARGLOG")" "--vad"
assert_not_contains "第二次不帶 VAD" "$(sed -n 2p "$T_ARGLOG")" "--vad"
assert_contains "重試用的是同一個主模型" "$(sed -n 2p "$T_ARGLOG")" "ggml-small-q5_1.bin"
assert_contains "log 記錄 VAD 重試" "$(t_log)" "retrying without VAD"

# ── VAD 重試也失敗 → 換 fallback model ──────────────────────
t_model ggml-tiny.bin
t_reset_log
out=$(t_run "FAKE_FAIL_MODELS=ggml-small-q5_1.bin" "FAKE_ECHO_MODEL=1" \
            "WHISPER_FALLBACK_MODEL=ggml-tiny.bin")
assert_eq       "主模型全失敗 → fallback model 接手" "$out" "from:ggml-tiny.bin"
assert_contains "log 記錄 fallback" "$(t_log)" "fallback model succeeded"

t_teardown; t_summary "C VAD"
