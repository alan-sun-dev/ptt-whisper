source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [F] 幻覺過濾"

run_with() { t_reset_log; t_run "FAKE_TEXT=$1"; }

# ── 使用 repo 提供的共用列表 ────────────────────────────────
mkdir -p "$T_PTT"
cp "$REPO/hallucinations_builtin.txt" "$T_PTT/"

assert_eq "exact match：Thank you."        "$(run_with 'Thank you.')" ""
assert_eq "exact match：謝謝觀看"          "$(run_with '謝謝觀看')" ""
assert_eq "exact match：ご視聴ありがとうございました" \
          "$(run_with 'ご視聴ありがとうございました')" ""
assert_eq "normalized：大小寫 + 去尾標點"  "$(run_with 'THANK YOU')" ""
assert_eq "normalized：全形句號"           "$(run_with '謝謝觀看。')" ""
assert_eq "純標點：..."                    "$(run_with '...')" ""
assert_eq "正常文字必須保留"               "$(run_with '今天天氣很好')" "今天天氣很好"
assert_eq "含幻覺詞的長句必須保留"         "$(run_with 'Thank you for the code review')" \
                                            "Thank you for the code review"

# ── 使用者自訂列表 ──────────────────────────────────────────
printf '# my list\n歡迎訂閱\n' > "$T_PTT/hallucinations.txt"
assert_eq "自訂列表生效" "$(run_with '歡迎訂閱')" ""
rm -f "$T_PTT/hallucinations.txt"

# ── 共用列表不存在 → 走硬編碼 fallback ──────────────────────
rm -f "$T_PTT/hallucinations_builtin.txt"
assert_eq "無共用列表 → fallback 仍能擋掉 Thank you." "$(run_with 'Thank you.')" ""
assert_contains "無共用列表 → log 警告" "$(t_log)" "hallucinations_builtin.txt not found"

t_teardown; t_summary "F hallucination"
