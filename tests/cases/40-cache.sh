source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [D] 快取"

# 迴歸測試：md5 必須在 runtime PATH 上找得到。
# 少了 /sbin 會讓 AUDIO_HASH 永遠是空字串、快取靜默失效（v3.7.0 修正的 bug）。
have_md5=$(env -i PATH="$RUNTIME_PATH" /bin/bash -c \
  'command -v md5 >/dev/null || command -v md5sum >/dev/null && echo yes || echo no')
assert_eq "runtime PATH 上找得到 md5/md5sum（P3-1 迴歸）" "$have_md5" "yes"

ncache() { local n; n=$(ls -1 "$T_PTT/cache" 2>/dev/null | grep -c . || true); echo "${n:-0}"; }

t_reset_log; out=$(t_run "FAKE_TEXT=first")
assert_eq "快取關閉 → 不建立快取檔" "$(ncache)" "0"
out=$(t_run "FAKE_TEXT=second")
assert_eq "快取關閉 → 每次重新推理" "$out" "second"

t_reset_log; out=$(t_run "WHISPER_CACHE=true" "FAKE_TEXT=cached-A")
assert_eq "快取開啟 → 首次寫入" "$out" "cached-A"
assert_eq "產生 1 個快取檔" "$(ncache)" "1"

t_reset_log; out=$(t_run "WHISPER_CACHE=true" "FAKE_TEXT=SHOULD-NOT-RUN")
assert_eq "相同輸入 → 命中快取" "$out" "cached-A"
assert_eq "命中快取 → 完全沒呼叫 whisper" "$(t_runs)" "0"

# ── 會改變輸出的參數必須改變 cache identity ──────────────────
out=$(t_run "WHISPER_CACHE=true" "WHISPER_PROMPT=p1" "FAKE_TEXT=with-prompt")
assert_eq "換 prompt → 不命中舊快取" "$out" "with-prompt"
out=$(t_run "WHISPER_CACHE=true" "WHISPER_PROMPT=p1" "FAKE_TEXT=SHOULD-NOT-RUN")
assert_eq "同 prompt 再跑 → 命中" "$out" "with-prompt"

out=$(t_run "WHISPER_CACHE=true" "WHISPER_MAX_CONTEXT=64" "FAKE_TEXT=with-mc")
assert_eq "換 max_context → 不命中舊快取" "$out" "with-mc"

t_model ggml-silero-v5.1.2.bin
out=$(t_run "WHISPER_CACHE=true" "FAKE_TEXT=with-vad")
assert_eq "VAD 狀態改變 → 不命中舊快取" "$out" "with-vad"

out=$(t_run "WHISPER_CACHE=true" "WHISPER_VAD=false" "FAKE_TEXT=SHOULD-NOT-RUN")
assert_eq "關掉 VAD → 命中最早那筆（VAD=false）" "$out" "cached-A"

# ── LRU 上限 ────────────────────────────────────────────────
before=$(ncache)
for i in 1 2 3 4 5 6 7 8; do
  t_run "WHISPER_CACHE=true" "WHISPER_CACHE_MAX=5" "WHISPER_PROMPT=lru-$i" \
        "FAKE_TEXT=lru$i" >/dev/null
done
after=$(ncache)
[[ "$after" -le 5 ]] && _t_ok "LRU 上限生效（$after ≤ 5）" \
                     || _t_bad "LRU 上限未生效（$after > 5）"

t_teardown; t_summary "D cache"
