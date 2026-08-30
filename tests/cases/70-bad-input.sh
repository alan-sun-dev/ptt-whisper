source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [G] 異常輸入"

out=$(t_run -- "$T_DIR/nope.wav"); rc=$?
assert_contains "不存在的 WAV → 明確錯誤" "$(t_stderr)" "audio file not found"
[[ $rc -ne 0 ]] && _t_ok "不存在的 WAV → 非零 exit" || _t_bad "應回非零 exit"

out=$(t_run -- "$TESTS/fixtures/too-small.wav"); rc=$?
assert_contains "過小的 WAV → 明確錯誤" "$(t_stderr)" "too small"
[[ $rc -ne 0 ]] && _t_ok "過小的 WAV → 非零 exit" || _t_bad "應回非零 exit"

out=$(t_run); rc=$?
[[ $rc -eq 0 ]] && _t_ok "無參數 → 使用預設路徑正常" || _t_bad "預設路徑應成功"

t_reset_log
out=$(t_run "WHISPER_CACHE_MAX=abc" "WHISPER_CACHE=true" "FAKE_TEXT=ok")
assert_eq "非法 WHISPER_CACHE_MAX → 不 crash，回退預設" "$out" "ok"

t_reset_log
out=$(t_run "WHISPER_TIMEOUT=abc" "FAKE_TEXT=ok" 2>/dev/null)
[[ -n "$out" ]] && _t_ok "非法 WHISPER_TIMEOUT → 不 crash" \
                || _t_bad "非法 WHISPER_TIMEOUT 造成失敗：$(t_stderr)"

# 8kHz 音訊：有 ffprobe 就該觸發 resample，沒有就略過
if command -v ffprobe >/dev/null 2>&1 && command -v ffmpeg >/dev/null 2>&1; then
  t_reset_log
  out=$(t_run "FAKE_TEXT=resampled" -- "$TESTS/fixtures/silence-8k-1s.wav")
  assert_eq "8kHz 音訊 → 自動 resample 後仍成功" "$out" "resampled"
  assert_contains "log 記錄 resample" "$(t_log)" "16kHz"
else
  t_skip "8kHz 自動 resample" "ffmpeg/ffprobe 不在 PATH"
fi

t_teardown; t_summary "G bad input"
