source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox
echo "  [A] 模型解析"

model_used() { t_args | sed -n 's/.*-m \([^ ]*\).*/\1/p' | xargs basename 2>/dev/null; }

t_reset_log; t_model ggml-small.bin
t_run >/dev/null; assert_eq "只有 FP16 → 用 FP16" "$(model_used)" "ggml-small.bin"

t_reset_log; t_model ggml-small-q8_0.bin
t_run >/dev/null; assert_eq "加入 q8_0 → 優先 q8_0" "$(model_used)" "ggml-small-q8_0.bin"

t_reset_log; t_model ggml-small-q5_0.bin
t_run >/dev/null; assert_eq "加入 q5_0 → 優先 q5_0" "$(model_used)" "ggml-small-q5_0.bin"

t_reset_log; t_model ggml-small-q5_1.bin
t_run >/dev/null; assert_eq "加入 q5_1 → 優先 q5_1（最高）" "$(model_used)" "ggml-small-q5_1.bin"

t_reset_log; t_model ggml-custom.bin
t_run "WHISPER_MODEL=$T_WD/models/ggml-custom.bin" >/dev/null
assert_eq "WHISPER_MODEL 覆寫一切" "$(model_used)" "ggml-custom.bin"

t_reset_log
t_run -- "$WAV" "" "ggml-small.bin" >/dev/null
assert_eq "第 3 個位置參數覆寫模型" "$(model_used)" "ggml-small.bin"

# 全部模型移除 → 明確錯誤而非靜默
rm -f "$T_WD/models/"*.bin
out=$(t_run); rc=$?
assert_contains "找不到任何模型 → 明確錯誤訊息" "$(t_stderr)" "model not found"
[[ $rc -ne 0 ]] && _t_ok "找不到模型 → 非零 exit" || _t_bad "找不到模型應回非零 exit"

t_teardown; t_summary "A model resolution"
