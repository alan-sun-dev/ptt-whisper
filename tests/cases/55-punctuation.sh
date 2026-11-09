source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"
t_sandbox; t_model ggml-small-q5_1.bin
echo "  [P] 中文標點轉全形"

# 這一關的重點不是「有沒有轉」，而是「該轉的轉、不該轉的一個都沒動」。
# 誤轉會破壞版本號、時間、識別碼與英文句子——那比不轉嚴重得多。

say() { t_reset_log; t_run "FAKE_TEXT=$1"; }

# ── 該轉的 ──────────────────────────────────────────────────
assert_eq "漢字後的逗號 → 全形" \
  "$(say '你好,世界')" "你好，世界"
assert_eq "漢字後的問號 → 全形" \
  "$(say '真的嗎?')" "真的嗎？"
assert_eq "漢字後的驚嘆號 → 全形" \
  "$(say '太好了!')" "太好了！"
assert_eq "漢字後的分號與冒號 → 全形" \
  "$(say '他說:好吧;算了')" "他說：好吧；算了"
assert_eq "一句話裡多個標點都要轉" \
  "$(say '來了,你是否習慣指繳?')" "來了，你是否習慣指繳？"

# ── 不該轉的（誤轉的代價比漏轉高）──────────────────────────
assert_eq "純英文句子完全不動" \
  "$(say 'API Error? Hello, world.')" "API Error? Hello, world."
assert_eq "版本號的點與逗號不動" \
  "$(say '4.1.2, ok')" "4.1.2, ok"
assert_eq "時間的冒號不動" \
  "$(say '12:30')" "12:30"
assert_eq "識別碼後的逗號不動" \
  "$(say 'HT-H7608, x')" "HT-H7608, x"
assert_eq "英文詞後的逗號不動（刻意保守）" \
  "$(say '我用 vLLM, 效果不錯')" "我用 vLLM, 效果不錯"
assert_eq "半形句點一律不動（與小數點無法區分）" \
  "$(say '好的.')" "好的."

# ── [PU2] 中英混雜：漢字在前但標點屬於 ASCII 語法 ──────────
# 初版只檢查「前一個字是漢字」，這三個都會被改壞。第三方 review 抓到的。
# 逗號前面確實是漢字，但那個逗號是 SQL 語法，不是中文標點。
assert_eq "SQL 中的中文欄位名後的逗號不動" \
  "$(say 'SELECT 姓名, age FROM users')" "SELECT 姓名, age FROM users"
assert_eq "中文詞後接英文的冒號不動" \
  "$(say 'Set 值: then continue')" "Set 值: then continue"
assert_eq "結尾的分號不動（中文散文不會用分號結尾）" \
  "$(say 'SELECT 值;')" "SELECT 值;"
assert_eq "分號後接空白不動" \
  "$(say '值; 然後')" "值; 然後"

# ── 只涵蓋中文，日韓刻意不處理 ──────────────────────────────
# 日文的逗號是「、」不是「，」，放寬到假名反而會產生排版錯誤的日文。
# 這條斷言存在的目的是**把這個限制釘住**，避免有人日後「順手」放寬判別式。
assert_eq "日文假名後的標點不動（刻意，日文用「、」不是「，」）" \
  "$(say 'これは?')" "これは?"
assert_eq "韓文諺文後的標點不動" \
  "$(say '안녕하세요?')" "안녕하세요?"

# ── 前面是全形但非漢字 ──────────────────────────────────────
assert_eq "全形句號後的半形逗號不動（前一字非漢字）" \
  "$(say '好。,壞')" "好。,壞"

# ── 邊界 ────────────────────────────────────────────────────
assert_eq "已經是全形 → 不重複處理" \
  "$(say '你好，世界')" "你好，世界"
assert_eq "沒有標點 → 原樣" \
  "$(say '你好世界')" "你好世界"

# ── 轉換失敗時必須保留原文，絕不能吃掉文字 ──────────────────
# 「perl 完全不存在」這條路徑測不到：查找是絕對路徑優先，PATH 蓋不掉
# （與 find_ffmpeg 同樣的情況）。但轉換失敗本身是可達的——餵進非法的
# UTF-8 位元組時，perl 會噴 Malformed UTF-8 警告而且 **stdout 是空的**。
# 這正是 guard 存在的理由：空輸出時必須退回原文，而不是把整句話弄不見。
t_reset_log
bad=$(printf '\xff\xfe')
out=$(t_run "FAKE_TEXT=你好${bad}世界")
[[ -n "$out" ]] \
  && _t_ok "轉換失敗（非法 UTF-8）→ 保留原文，文字沒有消失" \
  || _t_bad "轉換失敗時整句話被吃掉了"
assert_contains "轉換失敗 → log 說明降級" "$(t_log)" "punctuation normalize failed"

# ── 已知落差：快取命中會繞過整條文字管線 ────────────────────
# 這不是 bug 而是刻意的取捨（快取命中要快，且舊條目本來就是舊版產物），
# 但必須有斷言把這個行為釘住——否則它會被誤以為是壞掉而「修」錯方向。
t_reset_log
t_run "WHISPER_CACHE=true" "FAKE_TEXT=你好,世界" >/dev/null   # 第一次：轉換後存入
first=$(t_reset_log; t_run "WHISPER_CACHE=true" "FAKE_TEXT=你好,世界")
assert_eq "同一段音訊第二次 → 命中快取，拿到的是已轉換的版本" \
  "$first" "你好，世界"
assert_contains "確認第二次真的是命中快取" "$(t_log)" "CACHE HIT"

t_teardown; t_summary "P 中文標點"
